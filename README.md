# Azure Copilot Tool

Terraform module that deploys a Docker container behind an Azure Function REST endpoint, designed as a tool for Microsoft Copilot agents. Handles user-based Entra ID authentication with OBO (On-Behalf-Of) token exchange, so the container can call downstream APIs (e.g., Microsoft Graph) as the authenticated user.

## Architecture

```text
Copilot Agent (user auth via Entra ID)
  -> Azure Function (Easy Auth validates token)
     -> OBO token exchange (MSAL, gets downstream-scoped token)
     -> async: creates ephemeral ACI container, returns 202
        sync: proxies request to persistent ACI container, returns response
```

Resources provisioned:

- **Resource Group** with a random suffix for global uniqueness
- **Entra ID App Registration** with exposed API scope, service principal, client secret, and optional admin-consented delegated permissions
- **Azure Container Registry** (Basic SKU, admin auth) for storing your Docker image -- or bring your own
- **Key Vault** (RBAC-authorized) for secrets: Entra client secret, ACR password (when module-managed), and any custom secrets
- **Storage Account** for Function App runtime and deployment package
- **Function App** (Linux, Python 3.11, Consumption/Y1 plan) with Easy Auth and system-assigned managed identity
- **Container Instance** (sync mode only) as a persistent always-on container

## Execution Modes

**async** -- The Function creates a new ACI container group per request, passing the OBO token and request body as environment variables. Returns HTTP 202 immediately. An hourly timer trigger cleans up terminated containers older than `cleanup_threshold_hours`.

**sync** -- A persistent ACI container runs continuously. The Function proxies each request to it over HTTP, forwarding the OBO token in the `Authorization` header. The timer trigger is disabled.

## Prerequisites

- Azure subscription with permissions to create resources
- Entra ID permissions: Application Administrator (to create app registrations) and ideally Privileged Role Administrator (for automated admin consent of delegated permissions)
- Terraform >= 1.5
- Docker (to build and push your container image)
- Azure CLI (`az`) for authentication and image push

## Azure Concepts Quick Reference

If you're coming from AWS, a few Azure-isms to know:

- **Entra ID** (formerly Azure AD) is the identity platform. Comparable to IAM + Cognito combined.
- **App Registration** defines an application identity. Think of it as an OAuth client + API definition in one object.
- **Service Principal** is the runtime identity of an app registration within a tenant. Created automatically from the app registration.
- **Easy Auth** is built-in authentication middleware for Azure App Service/Functions. The platform validates tokens before your code runs, similar to an API Gateway authorizer.
- **OBO (On-Behalf-Of)** is an OAuth2 flow where a middle-tier service exchanges a user's token for a new token scoped to a downstream API. The Function uses this to get a token for Graph (or other APIs) on behalf of the calling user.
- **Key Vault references** (`@Microsoft.KeyVault(SecretUri=...)`) in app settings cause the Function runtime to resolve secrets at startup, no SDK calls needed in code.
- **ACI (Azure Container Instances)** is serverless container hosting. Think Fargate but simpler and with no orchestrator.

## Usage

### 1. Reference the module

Create a root Terraform configuration that calls this module. See `examples/basic/main.tf` for a complete example.

```hcl
provider "azurerm" {
  features {}
}

provider "azuread" {}

module "copilot_tool" {
  source = "github.com/lordjabez/terraform-azure-copilot-tool"

  location       = "eastus"
  project_name   = "my-tool"
  execution_mode = "async"
  container_image = "<acr_login_server>/my-tool:latest"

  obo_scopes = [
    "https://graph.microsoft.com/Sites.ReadWrite.All",
  ]

  delegated_permissions = {
    "00000003-0000-0000-c000-000000000000" = [
      { id = "89fe6a52-be36-487e-b7d8-d061c450a026", value = "Sites.ReadWrite.All" },
    ]
  }

  tags = {
    environment = "dev"
    team        = "platform"
  }
}
```

The `delegated_permissions` variable configures which API permissions the app registration declares and gets admin consent for. The keys are resource application IDs (e.g., `00000003-0000-0000-c000-000000000000` for Microsoft Graph) and values are lists of permission objects with `id` and `value`. You can find permission IDs in the [Microsoft Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference).

### Using an existing ACR

To skip ACR creation and use an externally-managed registry, set all three `existing_acr_*` variables:

```hcl
module "copilot_tool" {
  source = "github.com/lordjabez/terraform-azure-copilot-tool"

  # ...

  existing_acr_login_server   = "myregistry.azurecr.io"
  existing_acr_admin_username = "myregistry"
  existing_acr_admin_password = var.acr_password
}
```

When using an existing ACR, the `acr_login_server` and `acr_name` outputs are `null`.

### 2. Deploy

```bash
terraform init
terraform plan
terraform apply
```

### 3. Push a container image

After apply, use the output values to push your image:

```bash
ACR_NAME=$(terraform output -raw acr_name)
az acr login --name "${ACR_NAME}"
ACR_SERVER=$(terraform output -raw acr_login_server)
docker tag my-tool:latest "${ACR_SERVER}/my-tool:latest"
docker push "${ACR_SERVER}/my-tool:latest"
```

Or build directly in ACR:

```bash
az acr build -r "${ACR_NAME}" -t my-tool:latest .
```

The `container_image` variable must match what you push (e.g., `<acr_server>/my-tool:latest`). If deploying for the first time, you'll need to push the image before `terraform apply` if using sync mode (the persistent container must pull the image at creation time), or you can apply first in async mode and push later.

### 4. Test

```bash
CLIENT_ID=$(terraform output -raw app_registration_client_id)
TOKEN=$(az account get-access-token --resource "api://${CLIENT_ID}" --query accessToken -o tsv)
FUNCTION_URL=$(terraform output -raw function_url)

curl -X POST "${FUNCTION_URL}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"your": "payload"}'
```

In async mode, expect a 202 with a container group name. In sync mode, expect the proxied response from your container.

## Variable Reference

| Variable | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `location` | `string` | yes | | Azure region (e.g., `eastus`) |
| `project_name` | `string` | yes | | Resource name prefix. Lowercase alphanumeric + hyphens, 2-15 chars. |
| `execution_mode` | `string` | yes | | `async` or `sync` |
| `container_image` | `string` | yes | | Full image reference including tag |
| `obo_scopes` | `list(string)` | yes | | Scopes for OBO token exchange |
| `delegated_permissions` | `map(list(object))` | no | `{}` | API permissions to declare and consent. Key = resource app ID. |
| `container_env_vars` | `map(string)` | no | `{}` | Non-secret env vars passed to the container |
| `container_secret_env_var_names` | `set(string)` | no | `[]` | Names of secret env vars (stored in Key Vault) |
| `container_secret_env_var_values` | `map(string)` | no | `{}` | Values for secret env vars (sensitive). Keys must match names. |
| `container_cpu` | `number` | no | `2` | CPU cores for the container |
| `container_memory` | `number` | no | `4` | Memory in GB for the container |
| `container_port` | `number` | no | `8080` | Port the container listens on (sync mode) |
| `cleanup_threshold_hours` | `number` | no | `2` | Hours before terminated containers are cleaned up (async mode) |
| `api_scope_name` | `string` | no | `access_as_user` | Name of the exposed API scope |
| `existing_acr_login_server` | `string` | no | `null` | Login server of an existing ACR. Skips ACR creation. |
| `existing_acr_admin_username` | `string` | no | `null` | Admin username for the existing ACR |
| `existing_acr_admin_password` | `string` | no | `null` | Admin password for the existing ACR (sensitive) |
| `tags` | `map(string)` | no | `{}` | Tags applied to all supported resources and ephemeral containers |

## Outputs

| Output | Description |
| --- | --- |
| `function_url` | HTTPS endpoint (`/api/execute`) for the Copilot tool |
| `acr_login_server` | ACR hostname for `docker push` (null when using existing ACR) |
| `acr_name` | ACR resource name for `az acr login` (null when using existing ACR) |
| `app_registration_client_id` | Entra client ID for Copilot agent configuration |
| `keyvault_name` | Key Vault name for managing secrets outside Terraform |

## Notes

- **Admin consent**: Delegated permissions (e.g., `Sites.ReadWrite.All`) require admin consent. Terraform attempts this automatically via `azuread_service_principal_delegated_permission_grant`, but the deploying identity needs Privileged Role Administrator. If that's not available, grant consent manually: Azure Portal > Enterprise Applications > find the app > Permissions > Grant admin consent.

- **OBO token lifetime**: User tokens expire in 60-90 minutes. In async mode, if your container runs longer than this, the OBO token passed as an environment variable will expire mid-execution. Consider using application-level permissions instead of OBO for long-running tasks.

- **Client secret expiry**: The Entra client secret (`azuread_application_password`) expires after one year. To rotate, taint the resource and re-apply: `terraform taint module.copilot_tool.azuread_application_password.this && terraform apply`.

- **ACR admin credentials**: The module uses ACR admin auth for simplicity. This works for low-volume scenarios. For production, consider switching to managed identity-based image pull. You can also bring your own ACR via the `existing_acr_*` variables.

- **Function deployment**: The Function code is zipped and uploaded to blob storage with a SAS URL. The SAS token has a 1-year lifetime and is regenerated on each `terraform apply`, but the Function app setting that references it uses `ignore_changes` so the URL only updates when the function code itself changes (detected via MD5 hash in the blob name).

- **Tags**: The `tags` variable is merged onto all Azure resources that support tags. In async mode, tags are also applied to ephemeral ACI container groups (merged with the `created_at` timestamp tag used for cleanup).

## License

MIT-0
