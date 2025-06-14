# File: eprojects/iotdn2/databricks-rbac/main.tf

################################################################################
# Variables you can tweak                                                     #
################################################################################

variable "project_name" {
  description = "Name of the project"
  default     = "niotv1"
}

variable "environment" {
  description = "Environment (dev or prod)"
  default     = "dev"
}

variable "user_email" {
  description = "Email address of the Databricks user to add"
}

variable "databricks_host" {
  description = "The Databricks workspace URL"
}

variable "azure_client_id" {
  type        = string
  sensitive   = true
  description = "Service Principal client ID"
}

variable "azure_client_secret" {
  type        = string
  sensitive   = true
  description = "Service Principal client secret"
}

variable "azure_tenant_id" {
  type        = string
  sensitive   = true
  description = "Azure Tenant ID"
}

variable "subscription_id" {
  description = "Azure Subscription ID"
}

################################################################################
terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~>1.43.0"
    }
  }
}

provider "databricks" {
  host                        = var.databricks_host
  azure_client_id             = jsondecode(file("${path.module}/../../databricks-sp.json")).clientId
  azure_client_secret         = jsondecode(file("${path.module}/../../databricks-sp.json")).clientSecret
  azure_tenant_id             = jsondecode(file("${path.module}/../../databricks-sp.json")).tenantId
  azure_workspace_resource_id = local.workspace_resource_id
}

################################################################################
# Locals for naming & IDs                                                      #
################################################################################

locals {
  # e.g. "niotv1-dev"
  resource_name_prefix = "${var.project_name}-${var.environment}"

  # full ARM ID of the workspace
  workspace_resource_id = "/subscriptions/${var.subscription_id}/resourceGroups/${local.resource_name_prefix}-rg/providers/Microsoft.Databricks/workspaces/${local.resource_name_prefix}-databricks"

  # notebook path & content
  notebook_content = file("${path.module}/../modules/databricks/notebook_templates/iot_data_analysis.py")
  notebook_path    = "/${local.resource_name_prefix}-niotv1-data-analysis"
}



################################################################################
# RBAC Resources                                                               #
################################################################################

resource "databricks_group" "users" {
  display_name = "${local.resource_name_prefix}-databricks-users"
}

resource "databricks_entitlements" "users_entitlements" {
  group_id             = databricks_group.users.id
  allow_cluster_create = true
  workspace_access     = true
}

resource "databricks_cluster" "niotv1_cluster" {
  cluster_name            = "${local.resource_name_prefix}-cluster"
  spark_version           = "11.3.x-scala2.12"
  node_type_id            = "Standard_F4"
  num_workers             = 0
  autotermination_minutes = 60

  spark_conf = {
    "spark.databricks.cluster.profile" = "singleNode"
    "spark.master"                     = "local[*]"
  }

  custom_tags = {
    "ResourceClass" = "SingleNode"
    Environment     = var.environment
    Project         = var.project_name
  }
}


resource "databricks_user" "me" {
  user_name = var.user_email
}

resource "databricks_group_member" "me_user" {
  group_id  = databricks_group.users.id
  member_id = databricks_user.me.id
}

resource "databricks_notebook" "iot_analysis" {
  path           = local.notebook_path
  language       = "PYTHON"
  content_base64 = base64encode(local.notebook_content)
}

################################################################################
# Outputs                                                                      #
################################################################################

output "group_id" {
  value = databricks_group.users.id
}

output "cluster_id" {
  value = databricks_cluster.niotv1_cluster.id
}

output "notebook_path" {
  value = databricks_notebook.iot_analysis.path
}
