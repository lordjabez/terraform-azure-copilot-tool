# CLAUDE.md

## Project Overview

Generic Terraform module that deploys a Docker container behind an Azure Function as a tool for Microsoft Copilot agents. User auth flows through Entra ID Easy Auth, and the Function performs OBO token exchange to give the container a downstream-scoped token.

## Project Structure

This repo is a Terraform module. Consumers call it via a `module` block from their own root configuration. The `examples/` directory shows how.

```text
main.tf           # Terraform version + required providers, resource group, random suffix, base_name local
entra.tf          # App registration, service principal, client secret, API scope, delegated permission grants
acr.tf            # Container registry (Basic, admin enabled)
keyvault.tf       # Key Vault (RBAC), secrets for Entra client secret + ACR password + user secrets
function.tf       # Storage account, service plan (Y1), Function App, Easy Auth, role assignments, zip deploy
aci.tf            # Persistent container group (sync mode only, count-gated)
variables.tf      # 14 consumer-facing inputs
outputs.tf        # function_url, acr_login_server, app_registration_client_id, keyvault_name
function/
  function_app.py   # Python v2 Function: POST /api/execute + hourly cleanup timer
  requirements.txt  # azure-functions, azure-identity, azure-mgmt-containerinstance, msal, requests
  host.json         # Function host config
examples/
  basic/main.tf     # Sample root configuration calling this module
```

Provider blocks (`provider "azurerm"`, etc.) are NOT in the module. The caller's root configuration must declare them.

## Key Patterns

### Two Execution Modes

Controlled by `var.execution_mode`:

- **async**: Function creates an ephemeral ACI container group per request (named `{project_name}-{timestamp}`), passes OBO token and request body as env vars, returns 202. Timer trigger runs hourly to delete terminated containers.
- **sync**: A persistent ACI container (`aci.tf`, count-gated) runs continuously. Function proxies requests to it via HTTP. Timer trigger is disabled via `AzureWebJobs.cleanup.Disabled` app setting.

The `aci.tf` resource uses `count = var.execution_mode == "sync" ? 1 : 0`. In sync mode, the persistent container's IP is passed to the Function as `PERSISTENT_CONTAINER_IP`.

### Key Vault References

Secrets in Function app settings use the `@Microsoft.KeyVault(SecretUri=...)` syntax. The Function's managed identity has `Key Vault Secrets User` role on the vault. This means the Function runtime resolves secrets at startup without any SDK calls in the Python code.

The deploying Terraform identity gets `Key Vault Secrets Officer` to write secrets during apply.

### Easy Auth + OBO Flow

1. Easy Auth (configured in `auth_settings_v2`) validates the incoming token against the app registration before the Function code runs.
2. The validated user token is available in the `X-MS-TOKEN-AAD-ACCESS-TOKEN` header (requires `WEBSITE_AUTH_TOKEN_STORE_ENABLED = true`).
3. The Function uses MSAL to exchange that token via OBO flow for a new token scoped to `var.obo_scopes`.
4. In async mode, the OBO token is passed as a `secure_environment_variable` on the ACI container. In sync mode, it's sent as a Bearer token in the proxied HTTP request.

### Secret Variable Splitting

`container_secret_env_var_names` and `container_secret_env_var_values` are separate variables because Terraform cannot iterate over sensitive values. The names variable (non-sensitive `set(string)`) drives the `for_each` on Key Vault secrets, while the values variable (sensitive `map(string)`) provides the actual secret content. Keys must match between the two.

### Naming and Uniqueness

A 6-character random suffix (`random_string.suffix`) is appended to all resource names for global uniqueness. `project_name` is validated to be lowercase alphanumeric with hyphens, 2-16 characters.

ACR and storage account names strip hyphens (Azure requires alphanumeric-only for these resource types).

### Function Deployment

The `function/` directory is zipped via `archive_file`, uploaded to blob storage, and referenced by the Function App via `WEBSITE_RUN_FROM_PACKAGE` with a SAS URL. The blob name includes an MD5 hash, so changes to function code trigger redeployment.

## Validating Changes

```bash
terraform init    # first time or after provider changes
terraform validate
```

To validate the example:

```bash
cd examples/basic
terraform init
terraform validate
```

No automated tests exist. For Function code changes, review the Python manually since there's no test suite.

## Important Constraints

- **Module structure**: This repo is a reusable Terraform module. It must NOT contain `provider` blocks. Provider configuration is the caller's responsibility. The module declares `required_providers` with version constraints.

- **Circular dependency avoidance**: In sync mode, `function.tf` references `azurerm_container_group.persistent[0].ip_address` from `aci.tf`. The ACI resource references ACR credentials but not the Function, so no circular dependency exists. Be careful not to introduce one if adding dependencies between these resources.

- **ACI naming rules**: Container group names must be lowercase alphanumeric + hyphens, 1-63 chars. In async mode, names are generated as `{project_name}-{timestamp}` in the Python code. The cleanup timer identifies containers to delete by prefix-matching against `PROJECT_NAME`.

- **Provider versions**: `azurerm ~> 4.0` and `azuread ~> 3.0`. These are major version pins. Check migration guides before bumping.

- **timestamp() in app password**: `azuread_application_password.end_date` uses `timeadd(timestamp(), "8760h")` but has `lifecycle { ignore_changes = [end_date] }` to prevent churn. The `end_date` is only set on initial creation. To rotate the secret, taint the resource.

- **Admin-enabled ACR**: ACI image pull uses ACR admin credentials stored in Key Vault. The admin password is also used directly in the persistent container group definition (`aci.tf`). If switching to managed identity pull, both locations need updating.
