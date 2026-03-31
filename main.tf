terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${var.project_name}-${random_string.suffix.result}"
  location = var.location
  tags     = var.tags
}

locals {
  base_name = "${var.project_name}-${random_string.suffix.result}"

  create_acr       = var.existing_acr_login_server == null
  acr_login_server = local.create_acr ? azurerm_container_registry.this[0].login_server : var.existing_acr_login_server
  acr_username     = local.create_acr ? azurerm_container_registry.this[0].admin_username : var.existing_acr_admin_username
  acr_password     = local.create_acr ? azurerm_container_registry.this[0].admin_password : var.existing_acr_admin_password

  sas_start  = timestamp()
  sas_expiry = timeadd(timestamp(), "8760h")
}
