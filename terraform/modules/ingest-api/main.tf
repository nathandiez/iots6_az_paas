# File: modules/ingest-api/main.tf

###############################################################################
# Variables for this module                                                   #
###############################################################################

variable "resource_group_name" {
  description = "Name of the resource group"
}

variable "location" {
  description = "Azure region"
}

variable "project_name" {
  description = "Name of the project"
}

variable "environment" {
  description = "Environment (dev or prod)"
}

variable "api_key" {
  type        = string
  sensitive   = true
  description = "API key for authentication"
}

variable "storage_name" {
  description = "Name of the data lake Storage Account"
}

###############################################################################
# Storage account for data lake                                               #
###############################################################################

resource "azurerm_storage_account" "datalake" {
  name                     = var.storage_name
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"  # Required for static websites
  
  # Data Lake Gen2 requires hierarchical namespace
  is_hns_enabled = true
  
  # Your existing settings
  allow_nested_items_to_be_public = true
  min_tls_version               = "TLS1_2"
  enable_https_traffic_only     = true

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
  depends_on = [azurerm_storage_account.datalake]
  
  create_duration = "90s"  # Wait 90 seconds for Azure to fully provision
}

###############################################################################
# Container for raw data                                                      #
###############################################################################

resource "azurerm_storage_data_lake_gen2_filesystem" "rawdata" {
  name               = "rawdata"
  storage_account_id = azurerm_storage_account.datalake.id
  
  # Wait for storage account to be ready
  depends_on = [time_sleep.wait_for_storage]
}

###############################################################################
# App Service Plan (hosting plan)                                             #
###############################################################################

resource "azurerm_service_plan" "appplan" {
  name                = "${var.project_name}-${var.environment}-plan"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "B1"  # Basic tier, change as needed
}

###############################################################################
# App Service (where your API will run)                                       #
###############################################################################

resource "azurerm_linux_web_app" "api" {
  name                = "${var.project_name}-${var.environment}-api"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.appplan.id

  # Explicitly set https_only to false to allow HTTP access
  https_only = false

  site_config {
    application_stack {
      dotnet_version = "8.0"
    }
  }

  app_settings = {
    "APP_API_KEY"            = var.api_key
    "STORAGE_ACCOUNT_NAME"   = azurerm_storage_account.datalake.name
    "STORAGE_CONTAINER_NAME" = azurerm_storage_data_lake_gen2_filesystem.rawdata.name
    "WEBSITES_PORT"          = "8080"
    # Identity-based auth settings
    "AZURE_TENANT_ID"        = "" # You'll need to set this
    "AZURE_CLIENT_ID"        = "" # Will use managed identity
  }

  identity {
    type = "SystemAssigned"
  }
}

###############################################################################
# Grant the web app access to the storage account                              #
###############################################################################

resource "azurerm_role_assignment" "storage_contributor" {
  scope                = azurerm_storage_account.datalake.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_web_app.api.identity[0].principal_id
}

###############################################################################
# Outputs from this module                                                    #
###############################################################################

output "api_url" {
  # Changed to use HTTP instead of HTTPS
  value = "http://${azurerm_linux_web_app.api.default_hostname}/api/ingest"
}

output "storage_account_name" {
  value = azurerm_storage_account.datalake.name
}

output "container_name" {
  value = azurerm_storage_data_lake_gen2_filesystem.rawdata.name
}

output "storage_account_id" {
  value = azurerm_storage_account.datalake.id
}