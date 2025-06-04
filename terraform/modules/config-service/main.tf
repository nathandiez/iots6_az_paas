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
  account_kind             = "StorageV2"  # Required for static websites
  
  allow_nested_items_to_be_public = true
  min_tls_version               = "TLS1_0"  # Allows HTTP
  enable_https_traffic_only     = false

  # Extended timeouts to handle Azure provisioning delays
  timeouts {
    create = "45m"
    read   = "20m"    
    update = "45m"    
    delete = "45m"    
  }

  # Enable static website after storage account is created
  provisioner "local-exec" {
    command = <<-EOT
      sleep 30
      az storage blob service-properties update \
        --account-name ${self.name} \
        --static-website \
        --index-document index.html
    EOT
  }
}

# Add a time delay to ensure storage account is fully ready
resource "time_sleep" "wait_for_storage" {
  depends_on = [azurerm_storage_account.storage]
  
  create_duration = "90s"  # Wait 90 seconds for Azure to fully provision
}

# Wait for storage account to be fully provisioned before creating container
resource "azurerm_storage_container" "config_container" {
  name                  = "configs"
  storage_account_name  = azurerm_storage_account.storage.name
  container_access_type = "blob"

  depends_on = [time_sleep.wait_for_storage]
}

# Wait for container to be ready before uploading blobs
resource "azurerm_storage_blob" "config_files" {
  for_each = var.config_files
  
  name                   = each.key
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = azurerm_storage_container.config_container.name
  type                   = "Block"
  source                 = each.value

  depends_on = [azurerm_storage_container.config_container]
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

output "static_website_url" {
  value = azurerm_storage_account.storage.primary_web_endpoint
  description = "URL for the static website"
}