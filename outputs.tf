output "function_url" {
  description = "HTTPS endpoint for the Copilot tool"
  value       = "https://${azurerm_linux_function_app.this.default_hostname}/api/execute"
}

output "acr_login_server" {
  description = "ACR login server for docker push"
  value       = azurerm_container_registry.this.login_server
}

output "app_registration_client_id" {
  description = "Entra app registration client ID for Copilot agent configuration"
  value       = azuread_application.this.client_id
}

output "keyvault_name" {
  description = "Key Vault name for secret management"
  value       = azurerm_key_vault.this.name
}
