import json
import logging
import os
from datetime import datetime, timezone
from functools import lru_cache

import azure.functions as func
import msal
import requests
from azure.identity import DefaultAzureCredential
from azure.mgmt.containerinstance import ContainerInstanceManagementClient
from azure.mgmt.containerinstance.models import (
    Container,
    ContainerGroup,
    EnvironmentVariable,
    ImageRegistryCredential,
    OperatingSystemTypes,
    ResourceRequests,
    ResourceRequirements,
)

app = func.FunctionApp()

logger = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def _get_msal_app() -> msal.ConfidentialClientApplication:
    return msal.ConfidentialClientApplication(
        os.environ["ENTRA_CLIENT_ID"],
        authority=f"https://login.microsoftonline.com/{os.environ['ENTRA_TENANT_ID']}",
        client_credential=os.environ["ENTRA_CLIENT_SECRET"],
    )


@lru_cache(maxsize=1)
def _get_aci_client() -> ContainerInstanceManagementClient:
    return ContainerInstanceManagementClient(
        DefaultAzureCredential(),
        os.environ["SUBSCRIPTION_ID"],
    )


@lru_cache(maxsize=1)
def _get_static_env_vars() -> dict[str, str]:
    return json.loads(os.environ.get("CONTAINER_ENV_VARS", "{}"))


@lru_cache(maxsize=1)
def _get_container_tags() -> dict[str, str]:
    return json.loads(os.environ.get("CONTAINER_TAGS", "{}"))


@lru_cache(maxsize=1)
def _get_obo_scopes() -> list[str]:
    return [s.strip() for s in os.environ["OBO_SCOPES"].split(",")]


def _get_obo_token(user_token: str) -> dict:
    return _get_msal_app().acquire_token_on_behalf_of(
        user_assertion=user_token,
        scopes=_get_obo_scopes(),
    )


def _json_response(data: dict, status_code: int = 200) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps(data),
        status_code=status_code,
        mimetype="application/json",
    )


def _build_container_env_vars(obo_token: str, request_body: str) -> list[EnvironmentVariable]:
    env_vars = [
        EnvironmentVariable(name="OBO_TOKEN", secure_value=obo_token),
        EnvironmentVariable(name="REQUEST_BODY", value=request_body),
    ]

    for name, value in _get_static_env_vars().items():
        env_vars.append(EnvironmentVariable(name=name, value=value))

    secret_names = os.environ.get("CONTAINER_SECRET_ENV_VAR_NAMES", "")
    for name in filter(None, secret_names.split(",")):
        env_vars.append(EnvironmentVariable(name=name, secure_value=os.environ[name]))

    return env_vars


def _create_ephemeral_container(obo_token: str, request_body: str) -> str:
    resource_group = os.environ["RESOURCE_GROUP_NAME"]
    project_name = os.environ["PROJECT_NAME"]
    now = datetime.now(timezone.utc)
    container_group_name = f"{project_name}-{now.strftime('%Y%m%dt%H%M%S')}"

    container = Container(
        name=f"{project_name}-worker",
        image=os.environ["CONTAINER_IMAGE"],
        resources=ResourceRequirements(
            requests=ResourceRequests(
                cpu=float(os.environ["CONTAINER_CPU"]),
                memory_in_gb=float(os.environ["CONTAINER_MEMORY"]),
            )
        ),
        environment_variables=_build_container_env_vars(obo_token, request_body),
    )

    group = ContainerGroup(
        location=os.environ["LOCATION"],
        os_type=OperatingSystemTypes.LINUX,
        restart_policy="Never",
        containers=[container],
        image_registry_credentials=[
            ImageRegistryCredential(
                server=os.environ["ACR_LOGIN_SERVER"],
                username=os.environ["ACR_USERNAME"],
                password=os.environ["ACR_PASSWORD"],
            )
        ],
        tags={**_get_container_tags(), "created_at": now.isoformat()},
    )

    _get_aci_client().container_groups.begin_create_or_update(
        resource_group,
        container_group_name,
        group,
    )

    return container_group_name


def _proxy_to_persistent_container(obo_token: str, request_body: str, content_type: str) -> func.HttpResponse:
    ip = os.environ["PERSISTENT_CONTAINER_IP"]
    port = os.environ["CONTAINER_PORT"]

    headers = {
        "Authorization": f"Bearer {obo_token}",
        "Content-Type": content_type if content_type else "application/json",
    }

    resp = requests.post(f"http://{ip}:{port}/", data=request_body, headers=headers, timeout=300)

    return func.HttpResponse(
        body=resp.content,
        status_code=resp.status_code,
        headers={"Content-Type": resp.headers.get("Content-Type", "application/json")},
    )


@app.route(route="execute", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS)
def execute(req: func.HttpRequest) -> func.HttpResponse:
    user_token = req.headers.get("X-MS-TOKEN-AAD-ACCESS-TOKEN")
    if not user_token:
        return func.HttpResponse("Missing authentication token", status_code=401)

    obo_result = _get_obo_token(user_token)
    if "error" in obo_result:
        logger.error("OBO token exchange failed: %s", obo_result.get("error_description"))
        return _json_response(
            {"error": "Token exchange failed", "detail": obo_result.get("error_description")},
            status_code=500,
        )

    obo_token = obo_result["access_token"]
    request_body = req.get_body().decode("utf-8")

    if os.environ["EXECUTION_MODE"] == "async":
        container_group_name = _create_ephemeral_container(obo_token, request_body)
        return _json_response(
            {"container_group": container_group_name, "status": "accepted"},
            status_code=202,
        )

    return _proxy_to_persistent_container(
        obo_token,
        request_body,
        req.headers.get("Content-Type"),
    )


@app.timer_trigger(schedule="0 0 * * * *", arg_name="timer", run_on_startup=False)
def cleanup(timer: func.TimerRequest) -> None:
    if os.environ.get("EXECUTION_MODE") != "async":
        return

    resource_group = os.environ["RESOURCE_GROUP_NAME"]
    project_name = os.environ["PROJECT_NAME"]
    threshold_hours = int(os.environ.get("CLEANUP_THRESHOLD_HOURS", "2"))
    now = datetime.now(timezone.utc)

    for group in _get_aci_client().container_groups.list_by_resource_group(resource_group):
        if not group.name.startswith(project_name):
            continue

        if group.provisioning_state not in ("Succeeded", "Failed"):
            continue

        created_at_str = (group.tags or {}).get("created_at")
        if not created_at_str:
            continue

        created_at = datetime.fromisoformat(created_at_str)
        age_hours = (now - created_at).total_seconds() / 3600

        if age_hours >= threshold_hours:
            logger.info("Deleting terminated container group: %s (age: %.1f hours)", group.name, age_hours)
            try:
                _get_aci_client().container_groups.begin_delete(resource_group, group.name)
            except Exception:
                logger.exception("Failed to delete container group: %s", group.name)
