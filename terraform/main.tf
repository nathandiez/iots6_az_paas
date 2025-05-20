terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.109.0"
    }
  }
}

provider "azurerm" {
  features {}
}

################################################################################
#  Variables you can tweak                                                     #
################################################################################

variable "project_name" {
  description = "Name of the project"
  default     = "niotv1"
}

variable "environment" {
  description = "Environment (dev or prod)"
  default     = "dev"
}

variable "location" {
  description = "Azure region"
  default     = "East US 2"
}

variable "config_files" {
  description = "Map of config files to upload"
  type        = map(string)
  default     = {
    "pico_iot_config.json" = "../config-files/pico_iot_config.json"
  }
}

################################################################################
#  Locals for naming                                                            #
################################################################################

locals {
  # e.g. "niotv1-dev"
  raw_prefix = "${var.project_name}-${var.environment}"

  # strip hyphens, lower-case (for Azure storage account naming)
  sa_prefix = lower(replace(local.raw_prefix, "-", ""))

  # final storage-account names
  config_service_storage_name   = "${local.sa_prefix}storage"
  datalake_storage_account_name = "${local.sa_prefix}datalake"

  # re-usable dash-included prefix
  resource_name_prefix = local.raw_prefix
}

################################################################################
#  Data & Role Assignment                                                      #
################################################################################

data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "current_user_storage_data_owner_on_rg" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

################################################################################
#  Resource Group                                                              #
################################################################################

resource "azurerm_resource_group" "rg" {
  name     = "${local.resource_name_prefix}-rg"
  location = var.location
}

################################################################################
#  Config-Service Module                                                       #
################################################################################

module "config_service" {
  source              = "./modules/config-service"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location

  # storage account name now uses the prefix
  storage_name        = local.config_service_storage_name

  config_files        = var.config_files
}

################################################################################
#  Ingest-API Module                                                           #
################################################################################

module "ingest_api" {
  source              = "./modules/ingest-api"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  project_name        = var.project_name
  environment         = var.environment

  # data-lake storage account also uses the prefix
  storage_name        = local.datalake_storage_account_name
}

################################################################################
#  Databricks Module                                                           #
################################################################################

module "databricks" {
  source               = "./modules/databricks"
  resource_group_name  = azurerm_resource_group.rg.name
  location             = var.location
  project_name         = var.project_name
  environment          = var.environment
  data_lake_id         = module.ingest_api.storage_account_id
  data_lake_name       = module.ingest_api.storage_account_name
  data_lake_filesystem = module.ingest_api.container_name
}

################################################################################
#  Key Vault & Secrets                                                         #
################################################################################

resource "azurerm_key_vault" "kv" {
  name                        = "${local.resource_name_prefix}-kv"
  resource_group_name         = azurerm_resource_group.rg.name
  location                    = var.location
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  sku_name                    = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id
    
    # Add more permissions here
    key_permissions = [
      "Get", "List", "Create", "Delete", "Recover", "Purge", "Update"
    ]
    secret_permissions = [
      "Get", "List", "Set", "Delete", "Recover", "Purge", "Backup", "Restore"
    ]
    certificate_permissions = [
      "Get", "List", "Create", "Delete", "Recover", "Purge", "Update"
    ]
  }
}

resource "azurerm_key_vault_secret" "databricks_app_id" {
  name         = "databricks-app-id"
  value        = module.databricks.databricks_managed_identity_client_id
  key_vault_id = azurerm_key_vault.kv.id
}

resource "azurerm_key_vault_secret" "tenant_id" {
  name         = "tenant-id"
  value        = data.azurerm_client_config.current.tenant_id
  key_vault_id = azurerm_key_vault.kv.id
}

################################################################################
#  Outputs                                                                      #
################################################################################

output "config_service_storage_account_name" {
  value = module.config_service.storage_account_name
}

output "config_service_container_name" {
  value = module.config_service.container_name
}

output "config_service_urls" {
  description = "URLs for the config files"
  value       = module.config_service.config_urls
}

output "ingest_api_url" {
  description = "The base URL for the Ingest API."
  value       = module.ingest_api.api_url
}

output "databricks_workspace_url" {
  value = module.databricks.databricks_workspace_url
}

output "ingest_api_storage_account_name" {
  description = "The name of the storage account used by the Ingest API for the data lake."
  value       = module.ingest_api.storage_account_name
}

output "ingest_api_container_name" {
  description = "The name of the container (filesystem) in the Ingest API data lake."
  value       = module.ingest_api.container_name
}

output "key_vault_name" {
  value = azurerm_key_vault.kv.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.kv.vault_uri
}

output "key_vault_id" {
  value = azurerm_key_vault.kv.id
}
