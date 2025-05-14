# Assign Contributor role to the current user for the Databricks workspace
resource "azurerm_role_assignment" "databricks_contributor" {
  scope                = azurerm_databricks_workspace.databricks.id
  role_definition_name = "Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Assign Contributor role to the current user for the resource group
resource "azurerm_role_assignment" "resource_group_contributor" {
  scope                = azurerm_resource_group.rg.id
  role_definition_name = "Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Output the user information for reference
output "current_user_principal_id" {
  value = data.azurerm_client_config.current.object_id
}