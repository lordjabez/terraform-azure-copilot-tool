output "function_url" {
  description = "HTTPS endpoint for the Copilot tool"
  value       = "https://${azurerm_linux_function_app.this.default_hostname}/api/execute"
}

output "acr_login_server" {
  description = "ACR login server for docker push (null when using an existing ACR)"
  value       = local.create_acr ? azurerm_container_registry.this[0].login_server : null
}

output "acr_name" {
  description = "ACR name for az acr login (null when using an existing ACR)"
  value       = local.create_acr ? azurerm_container_registry.this[0].name : null
}

output "app_registration_client_id" {
  description = "Entra app registration client ID for Copilot agent configuration"
  value       = azuread_application.this.client_id
}

output "keyvault_name" {
  description = "Key Vault name for secret management"
  value       = azurerm_key_vault.this.name
}
