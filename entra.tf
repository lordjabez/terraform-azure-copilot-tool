resource "random_uuid" "scope_id" {}

resource "azuread_application" "this" {
  display_name     = "${var.project_name}-copilot-tool"
  sign_in_audience = "AzureADMyOrg"

  api {
    oauth2_permission_scope {
      admin_consent_description  = "Allow the Copilot agent to call this tool on behalf of the signed-in user"
      admin_consent_display_name = "Access ${var.project_name} as user"
      enabled                    = true
      id                         = random_uuid.scope_id.result
      type                       = "User"
      value                      = var.api_scope_name
    }
  }

  web {
    implicit_grant {
      access_token_issuance_enabled = true
    }
  }

  dynamic "required_resource_access" {
    for_each = var.delegated_permissions

    content {
      resource_app_id = required_resource_access.key

      dynamic "resource_access" {
        for_each = required_resource_access.value

        content {
          id   = resource_access.value.id
          type = "Scope"
        }
      }
    }
  }
}

resource "azuread_application_identifier_uri" "this" {
  application_id = azuread_application.this.id
  identifier_uri = "api://${azuread_application.this.client_id}"
}

resource "azuread_service_principal" "this" {
  client_id = azuread_application.this.client_id
}

resource "azuread_application_password" "this" {
  application_id = azuread_application.this.id
  display_name   = "obo-secret"
  end_date       = timeadd(timestamp(), "8760h")

  lifecycle {
    ignore_changes = [end_date]
  }
}

# Requires Privileged Role Administrator in Entra ID. If the deploying identity
# lacks this, grant consent manually via Azure Portal > Enterprise Applications.
resource "azuread_service_principal_delegated_permission_grant" "this" {
  for_each = var.delegated_permissions

  service_principal_object_id          = azuread_service_principal.this.object_id
  resource_service_principal_object_id = data.azuread_service_principal.resource[each.key].object_id
  claim_values                         = [for perm in each.value : perm.value]
}

data "azuread_service_principal" "resource" {
  for_each  = var.delegated_permissions
  client_id = each.key
}
