resource "azurerm_storage_account" "this" {
  name                     = replace("st${local.base_name}", "-", "")
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = var.tags

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_service_plan" "this" {
  name                = "asp-${local.base_name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = var.tags
}

data "archive_file" "function_code" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/.build/function.zip"
}

resource "azurerm_storage_container" "deployments" {
  name               = "function-deployments"
  storage_account_id = azurerm_storage_account.this.id
}

resource "azurerm_storage_blob" "function_code" {
  name                   = "function-${data.archive_file.function_code.output_md5}.zip"
  storage_account_name   = azurerm_storage_account.this.name
  storage_container_name = azurerm_storage_container.deployments.name
  type                   = "Block"
  source                 = data.archive_file.function_code.output_path
}

data "azurerm_storage_account_sas" "function_code" {
  connection_string = azurerm_storage_account.this.primary_connection_string
  https_only        = true
  signed_version    = "2022-11-02"

  start  = local.sas_start
  expiry = local.sas_expiry

  resource_types {
    service   = false
    container = false
    object    = true
  }

  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }

  permissions {
    read    = true
    write   = false
    delete  = false
    list    = false
    add     = false
    create  = false
    update  = false
    process = false
    tag     = false
    filter  = false
  }
}

locals {
  function_package_url = "https://${azurerm_storage_account.this.name}.blob.core.windows.net/${azurerm_storage_container.deployments.name}/${azurerm_storage_blob.function_code.name}${data.azurerm_storage_account_sas.function_code.sas}"

  acr_password_setting = local.create_acr ? (
    "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.acr_password[0].versionless_id})"
  ) : var.existing_acr_admin_password

  base_app_settings = {
    WEBSITE_AUTH_TOKEN_STORE_ENABLED = "true"
    ENTRA_CLIENT_ID                  = azuread_application.this.client_id
    ENTRA_CLIENT_SECRET              = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.entra_client_secret.versionless_id})"
    ENTRA_TENANT_ID                  = data.azurerm_client_config.current.tenant_id
    OBO_SCOPES                       = join(",", var.obo_scopes)
    EXECUTION_MODE                   = var.execution_mode
    CONTAINER_IMAGE                  = var.container_image
    RESOURCE_GROUP_NAME              = azurerm_resource_group.this.name
    SUBSCRIPTION_ID                  = data.azurerm_client_config.current.subscription_id
    CONTAINER_CPU                    = tostring(var.container_cpu)
    CONTAINER_MEMORY                 = tostring(var.container_memory)
    CONTAINER_PORT                   = tostring(var.container_port)
    CLEANUP_THRESHOLD_HOURS          = tostring(var.cleanup_threshold_hours)
    PROJECT_NAME                     = var.project_name
    LOCATION                         = azurerm_resource_group.this.location
    ACR_LOGIN_SERVER                 = local.acr_login_server
    ACR_USERNAME                     = local.acr_username
    ACR_PASSWORD                     = local.acr_password_setting
    CONTAINER_ENV_VARS               = jsonencode(var.container_env_vars)
    CONTAINER_SECRET_ENV_VAR_NAMES   = join(",", var.container_secret_env_var_names)
    CONTAINER_TAGS                   = jsonencode(var.tags)
    WEBSITE_RUN_FROM_PACKAGE         = local.function_package_url
  }

  secret_app_settings = {
    for name, secret in azurerm_key_vault_secret.container_secrets :
    name => "@Microsoft.KeyVault(SecretUri=${secret.versionless_id})"
  }

  mode_app_settings = var.execution_mode == "sync" ? {
    PERSISTENT_CONTAINER_IP         = azurerm_container_group.persistent[0].ip_address
    "AzureWebJobs.cleanup.Disabled" = "true"
  } : {}

  app_settings = merge(local.base_app_settings, local.secret_app_settings, local.mode_app_settings)
}

resource "azurerm_linux_function_app" "this" {
  name                = "func-${local.base_name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  service_plan_id     = azurerm_service_plan.this.id
  tags                = var.tags

  https_only = true

  storage_account_name       = azurerm_storage_account.this.name
  storage_account_access_key = azurerm_storage_account.this.primary_access_key

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      python_version = "3.11"
    }
  }

  auth_settings_v2 {
    auth_enabled           = true
    require_authentication = true
    unauthenticated_action = "Return401"

    active_directory_v2 {
      client_id            = azuread_application.this.client_id
      tenant_auth_endpoint = "https://login.microsoftonline.com/${data.azurerm_client_config.current.tenant_id}/v2.0"
      allowed_audiences    = ["api://${azuread_application.this.client_id}"]
    }

    login {}
  }

  app_settings = local.app_settings

  lifecycle {
    ignore_changes = [app_settings["WEBSITE_RUN_FROM_PACKAGE"]]
  }
}

resource "azurerm_role_assignment" "function_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_function_app.this.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_kv_reader" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.this.identity[0].principal_id
}
