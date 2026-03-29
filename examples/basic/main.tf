terraform {
  required_version = ">= 1.5"
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

module "copilot_tool" {
  source = "../.."

  location       = "eastus"
  project_name   = "my-tool"
  execution_mode = "async"
  container_image = "myacr.azurecr.io/my-tool:latest"

  obo_scopes = [
    "https://graph.microsoft.com/Sites.ReadWrite.All",
  ]

  # Microsoft Graph app ID with the scope ID and value for Sites.ReadWrite.All
  delegated_permissions = {
    "00000003-0000-0000-c000-000000000000" = [
      { id = "89fe6a52-be36-487e-b7d8-d061c450a026", value = "Sites.ReadWrite.All" },
    ]
  }
}

output "function_url" {
  value = module.copilot_tool.function_url
}

output "acr_login_server" {
  value = module.copilot_tool.acr_login_server
}

output "app_registration_client_id" {
  value = module.copilot_tool.app_registration_client_id
}

output "keyvault_name" {
  value = module.copilot_tool.keyvault_name
}
