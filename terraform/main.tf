# terraform/main.tf
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0"
}

# Configure the Azure Provider with better resource deletion handling
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
  # Assumes authentication via Azure CLI (run `az login`)
}

# --- Resource Definitions (Hardcoded) ---

# 1. Resource Group
resource "random_string" "rg_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "rg" {
  name     = "iot-azure-rg-${random_string.rg_suffix.result}"
  location = "eastus2"

  timeouts {
    create = "30m"
    delete = "30m"
  }
}


# 2. ADLS Gen2 Storage Account
resource "random_string" "storage_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_storage_account" "sa" {
  name                     = "iotlearn2024${random_string.storage_suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  is_hns_enabled           = false

  static_website {
    index_document     = "index.html"
    error_404_document = "error404.html"
  }

  timeouts {
    create = "60m"
    delete = "30m"
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
  name                = "iot-asp-${random_string.rg_suffix.result}" # Changed to dynamic name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1" # Basic tier

  # Add explicit timeouts
  timeouts {
    create = "30m"
    delete = "30m"
  }
}

# 5. App Service (Linux Web App for .NET API)
resource "azurerm_linux_web_app" "api_app" {
  name                = "iot-api-4serveconfig" # STATIC NAME 
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

  # Add explicit timeouts
  timeouts {
    create = "30m"
    delete = "30m"
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

# 10. Databricks Workspace
resource "azurerm_databricks_workspace" "databricks" {
  name                = "iot-databricks-${random_string.rg_suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = "eastus2"
  sku                 = "standard"

  tags = {
    Environment = "Development"
  }

  # Add explicit timeouts - longer for Databricks since it's more complex
  timeouts {
    create = "60m"
    delete = "60m"
  }
}

# 11. Output the Databricks Workspace URL
output "databricks_workspace_url" {
  value = azurerm_databricks_workspace.databricks.workspace_url
}

# 12. Output the Storage Account name 
output "storage_account_name" {
  value = azurerm_storage_account.sa.name
}

# 13. Output the Storage Account ID
output "storage_account_id" {
  value = azurerm_storage_account.sa.id
}

# 14. Output the Web App name
output "web_app_name" {
  value = azurerm_linux_web_app.api_app.name
}

# 15. Output the Resource Group name
output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

# 16. Output the Databricks Workspace name
output "databricks_workspace_name" {
  value = azurerm_databricks_workspace.databricks.name
}