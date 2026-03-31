resource "azurerm_container_registry" "this" {
  count = local.create_acr ? 1 : 0

  name                = replace("acr${local.base_name}", "-", "")
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = true
  tags                = var.tags
}
