# modules/config-service/main.tf

# Variables for this module
variable "resource_group_name" {
  description = "Name of the resource group"
}

variable "location" {
  description = "Azure region"
}

variable "storage_name" {
  description = "Name of the storage account"
}

variable "config_files" {
  description = "Map of config files to upload"
  type        = map(string)
}

# Resources
resource "azurerm_storage_account" "storage" {
  name                     = var.storage_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  
  allow_nested_items_to_be_public = true
  min_tls_version               = "TLS1_0"  # Allows HTTP
  enable_https_traffic_only     = false
}

resource "azurerm_storage_container" "config_container" {
  name                  = "configs"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "blob"
}

resource "azurerm_storage_blob" "config_files" {
  for_each = var.config_files
  
  name                   = each.key
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = azurerm_storage_container.config_container.name
  type                   = "Block"
  source                 = each.value
}

# Outputs from this module
output "storage_account_name" {
  value = azurerm_storage_account.storage.name
}

output "container_name" {
  value = azurerm_storage_container.config_container.name
}

output "config_urls" {
  value = {
    for filename, _ in var.config_files :
    filename => "http://${azurerm_storage_account.storage.name}.blob.core.windows.net/${azurerm_storage_container.config_container.name}/${filename}"
  }
}