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
  description = "API key for authentication"
  default     = "SuperSecretKey123ChangeMeLater"
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
  account_kind             = "StorageV2"
  is_hns_enabled           = true  # Hierarchical namespace for Data Lake
}

###############################################################################
# Container for raw data                                                      #
###############################################################################

resource "azurerm_storage_data_lake_gen2_filesystem" "rawdata" {
  name               = "rawdata"
  storage_account_id = azurerm_storage_account.datalake.id
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
