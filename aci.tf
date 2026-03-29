resource "azurerm_container_group" "persistent" {
  count = var.execution_mode == "sync" ? 1 : 0

  name                = "aci-${local.base_name}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  os_type             = "Linux"
  restart_policy      = "Always"
  ip_address_type     = "Public"

  image_registry_credential {
    server   = azurerm_container_registry.this.login_server
    username = azurerm_container_registry.this.admin_username
    password = azurerm_container_registry.this.admin_password
  }

  container {
    name   = "${var.project_name}-container"
    image  = var.container_image
    cpu    = var.container_cpu
    memory = var.container_memory

    ports {
      port     = var.container_port
      protocol = "TCP"
    }

    environment_variables        = var.container_env_vars
    secure_environment_variables = var.container_secret_env_var_values
  }
}
