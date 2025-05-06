# terraform/main.tf - Fixed version with data source and user permissions

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0"
}

# Configure the Azure Provider
provider "azurerm" {
  features {}
  # Assumes authentication via Azure CLI (run `az login`)
}

# --- Resource Definitions (Hardcoded) ---

# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "iot-azure-rg" # Simple hardcoded name
  location = "eastus2"
}

# 2. ADLS Gen2 Storage Account
resource "azurerm_storage_account" "sa" {
  name                     = "iotlearn2024ned" # Updated to unique name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  is_hns_enabled           = true # Enable Hierarchical Namespace (ADLS Gen2)

  # Allow all network access for initial simplicity
  network_rules {
    default_action = "Allow"
    bypass         = ["AzureServices"]
  }
}

# 3. Storage Container
resource "azurerm_storage_container" "raw_data_container" {
  name                  = "rawdata"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

# 4. App Service Plan (Linux)
resource "azurerm_service_plan" "asp" {
  name                = "iot-azure-asp" # Simple hardcoded name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1" # Basic tier
}

# 5. App Service (Linux Web App for .NET API)
resource "azurerm_linux_web_app" "api_app" {
  name                = "iot-azure-api-app-ned" # Consider making this dynamic/variable
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.asp.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_stack {
      dotnet_version = "8.0" # Assuming .NET 8
    }
    always_on = false
  }

  app_settings = {
    # !! INSECURE - Hardcoded key for initial testing only !!
    # Consider using Key Vault reference later: "@Microsoft.KeyVault(SecretUri=...)"
    "APP_API_KEY"            = "SuperSecretKey123!ChangeMeLater"
    "STORAGE_ACCOUNT_NAME"   = azurerm_storage_account.sa.name
    "STORAGE_CONTAINER_NAME" = azurerm_storage_container.raw_data_container.name
  }
}

# 6. Data source to get the App Service with its identity
data "azurerm_linux_web_app" "api_app_data" {
  name                = azurerm_linux_web_app.api_app.name
  resource_group_name = azurerm_resource_group.rg.name

  depends_on = [azurerm_linux_web_app.api_app]
}

# 7. Get current client configuration (to get the current user's info)
data "azurerm_client_config" "current" {}

# 8. Grant App Service Managed Identity access to Storage Account
resource "azurerm_role_assignment" "adls_write_access" {
  scope                = azurerm_storage_account.sa.id                                    # The resource ID the role applies to (the storage account)
  role_definition_name = "Storage Blob Data Contributor"                                  # The role needed to write data
  principal_id         = data.azurerm_linux_web_app.api_app_data.identity[0].principal_id # The principal ID of the App Service's Managed Identity

  depends_on = [
    data.azurerm_linux_web_app.api_app_data,
    azurerm_storage_account.sa
  ]
}

# 9. Grant current user access to Storage Account (for development)
resource "azurerm_role_assignment" "current_user_access" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id

  # Optional: Add a description to clarify this is for development access
  description = "Grant developer access to storage account for testing and debugging"

  depends_on = [
    azurerm_storage_account.sa
  ]
}