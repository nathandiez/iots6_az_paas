# Updated Guide: Adding a Service Principal for Databricks Automation

This guide shows how to create and integrate a non-human Azure Service Principal (SP) for automating Databricks workspace operations using Terraform.

---

## 1. Create the Service Principal (SP)

1. **Get your subscription ID**

   ```bash
   az account show --query id -o tsv
   ```

2. **Create the SP scoped only to your Databricks workspace**
   Replace `YOUR_SUBSCRIPTION_ID`, `YOUR_RG`, and `YOUR_WORKSPACE_NAME` below:

   ```bash
   az ad sp create-for-rbac \
     --name databricks-niotv1-sp \
     --role Contributor \
     --scopes "/subscriptions/YOUR_SUBSCRIPTION_ID/resourceGroups/YOUR_RG/providers/Microsoft.Databricks/workspaces/YOUR_WORKSPACE_NAME" \
     --sdk-auth > databricks-sp.json
   ```

   > **Note:** Output JSON contains `clientId` (SP ID), `clientSecret`, `subscriptionId` and `tenantId`. Keep it safe!

---

## 2. Deploy Main Infrastructure

```bash
./deploy.sh --infra
```

This will create your resource group, storage accounts, App Service, and the Databricks workspace.

---

## 3. Grant the SP Owner on the Databricks Workspace

Fetch the workspace’s ARM-ID:

```bash
WORKSPACE_ID=$(az databricks workspace show \
  --name niotv1-dev-databricks \
  --resource-group niotv1-dev-rg \
  --query id -o tsv)
```

Then assign **Owner** to your SP on that exact workspace:

```bash
az role assignment create \
  --assignee "$(jq -r .clientId databricks-sp.json)" \
  --role Owner \
  --scope "$WORKSPACE_ID"
```

---

## 4. Parameterize Terraform’s Databricks Provider

In `terraform/databricks-rbac/main.tf`, switch from hard-coded defaults to using your SP values and a computed `azure_workspace_resource_id`:

```hcl
variable "subscription_id" { default = "b55db986-8fb7-4627-8ae4-f4a8ad081051" }
variable "project_name"    { default = "niotv1" }
variable "environment"     { default = "dev" }

locals {
  prefix              = "${var.project_name}-${var.environment}"
  workspace_id_prefix = "/subscriptions/${var.subscription_id}" +
                        "/resourceGroups/${local.prefix}-rg" +
                        "/providers/Microsoft.Databricks/workspaces/${local.prefix}-databricks"
}

provider "databricks" {
  host                        = var.databricks_host
  azure_client_id             = file("${path.root}/databricks-sp.json")["clientId"]
  azure_client_secret         = file("${path.root}/databricks-sp.json")["clientSecret"]
  azure_tenant_id             = file("${path.root}/databricks-sp.json")["tenantId"]
  azure_workspace_resource_id = local.workspace_id_prefix
}
```

This way you never check secrets into Git, and the workspace-ID is derived automatically.

---

## 5. Deploy RBAC

```bash
./deploy.sh --dbrbac
```

That script will:

1. Wait for the workspace to be healthy
2. Inject the correct `databricks_host` into `terraform.tfvars`
3. Apply your Databricks RBAC Terraform

---

## 6. Verify

* Log into your workspace URL
* Confirm the `databricks-users` group, cluster and notebook exist
* Add yourself (e.g. `nathandiez12@gmail.com`) via the UI or Terraform if you need UI access

---

## 7. Cleanup

```bash
./deploy.sh --destroy
```

---

### Troubleshooting

* **Deny assignments**: Databricks-managed RGs have system-deny assignments on their storage. You won’t be able to list keys there—use your data-lake account instead.
* **Cluster permissions**: Your SP needs both **Contributor** on the workspace and **Owner** to run REST API calls.
* **Token errors**: If you see `AADSTS7000229`, double-check your SP exists in the right tenant and you used the correct `tenantId`.

---

This flow keeps your SP scoped as narrowly as possible, avoids leaked secrets in Git, and uses Terraform-driven naming conventions so everything stays consistent.
