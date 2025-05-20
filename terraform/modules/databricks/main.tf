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

variable "data_lake_id" {
  description = "ID of the Data Lake storage account"
}

variable "data_lake_name" {
  description = "Name of the Data Lake storage account"
}

variable "data_lake_filesystem" {
  description = "Name of the Data Lake filesystem"
}

locals {
  workspace_name = "${var.project_name}-${var.environment}-databricks"
  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

# Databricks Workspace
resource "azurerm_databricks_workspace" "databricks" {
  name                = local.workspace_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.environment == "prod" ? "premium" : "standard"
  
  tags = local.tags
}

# Create a service principal for the Databricks workspace
resource "azurerm_user_assigned_identity" "databricks_identity" {
  name                = "${local.workspace_name}-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
}

# Grant the Databricks identity access to the data lake
resource "azurerm_role_assignment" "databricks_storage_contributor" {
  scope                = var.data_lake_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.databricks_identity.principal_id
}

resource "azurerm_role_assignment" "databricks_storage_owner" {
  scope                = var.data_lake_id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_user_assigned_identity.databricks_identity.principal_id
}

output "databricks_workspace_url" {
  value = azurerm_databricks_workspace.databricks.workspace_url
}

output "databricks_workspace_id" {
  value = azurerm_databricks_workspace.databricks.id
}

output "databricks_host" {
  value = "https://${azurerm_databricks_workspace.databricks.workspace_url}"
}

output "databricks_managed_identity_id" {
  value = azurerm_user_assigned_identity.databricks_identity.id
}

output "databricks_managed_identity_principal_id" {
  value = azurerm_user_assigned_identity.databricks_identity.principal_id
}

output "databricks_managed_identity_client_id" {
  value = azurerm_user_assigned_identity.databricks_identity.client_id
}