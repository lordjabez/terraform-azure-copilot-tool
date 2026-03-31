variable "location" {
  description = "Azure region for all resources"
  type        = string
}

variable "project_name" {
  description = "Naming prefix for all resources"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,13}[a-z0-9]$", var.project_name))
    error_message = "Must be lowercase alphanumeric with hyphens, 2-15 characters, cannot start or end with a hyphen."
  }
}

variable "execution_mode" {
  description = "Container execution model: 'async' (ephemeral per-request) or 'sync' (persistent always-on)"
  type        = string

  validation {
    condition     = contains(["async", "sync"], var.execution_mode)
    error_message = "Must be 'async' or 'sync'."
  }
}

variable "container_image" {
  description = "Full Docker image reference including tag, e.g. myacr.azurecr.io/myapp:latest"
  type        = string
}

variable "obo_scopes" {
  description = "Scopes for the OBO token exchange, e.g. [\"https://graph.microsoft.com/Sites.ReadWrite.All\"]"
  type        = list(string)
}

variable "delegated_permissions" {
  description = "Map of resource app ID to list of permission objects with id and value"
  type = map(list(object({
    id    = string
    value = string
  })))
  default = {}
}

variable "container_env_vars" {
  description = "Non-secret environment variables passed to the container"
  type        = map(string)
  default     = {}
}

variable "container_secret_env_var_names" {
  description = "Names of secret environment variables (used as Key Vault secret names and container env var keys)"
  type        = set(string)
  default     = []
}

variable "container_secret_env_var_values" {
  description = "Values for secret environment variables, keyed by name. Must match container_secret_env_var_names."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "container_cpu" {
  description = "CPU cores allocated to the container"
  type        = number
  default     = 2
}

variable "container_memory" {
  description = "Memory in GB allocated to the container"
  type        = number
  default     = 4
}

variable "container_port" {
  description = "Port the container listens on (used in sync mode)"
  type        = number
  default     = 8080
}

variable "cleanup_threshold_hours" {
  description = "Hours before terminated containers are cleaned up (async mode)"
  type        = number
  default     = 2
}

variable "api_scope_name" {
  description = "Name of the exposed API scope on the Entra app registration"
  type        = string
  default     = "access_as_user"
}

variable "existing_acr_login_server" {
  description = "Login server of an existing ACR. When set, the module skips ACR creation and uses this registry instead. All three existing_acr_* variables must be set together."
  type        = string
  default     = null

  validation {
    condition = (
      var.existing_acr_login_server == null
      ? true
      : var.existing_acr_admin_username != null && var.existing_acr_admin_password != null
    )
    error_message = "When existing_acr_login_server is set, existing_acr_admin_username and existing_acr_admin_password must also be set."
  }
}

variable "existing_acr_admin_username" {
  description = "Admin username for the existing ACR"
  type        = string
  default     = null
}

variable "existing_acr_admin_password" {
  description = "Admin password for the existing ACR"
  type        = string
  default     = null
  sensitive   = true
}

variable "tags" {
  description = "Tags to apply to all supported resources"
  type        = map(string)
  default     = {}
}
