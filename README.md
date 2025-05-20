## General Improvements

1. **Add a "Quick Start" section** at the beginning for users who want to get running immediately
2. **Include information about the Service Principal** setup that we implemented
3. **Improve scripts section** to mention the additional utilities like `deploy.sh`, `destroy_all.sh`, and `show_resources.sh`
4. **Add architecture diagram placeholder** - suggesting you could add a diagram later

## Specific Enhancements

### Quick Start Section (to add near the beginning)

```markdown
## Quick Start

For rapid deployment:

1. Clone this repository
2. Run `./deploy.sh` to deploy all infrastructure
3. Run `./deploy.sh --dbrbac` to configure Databricks with Service Principal
4. Run `./test_datalake.sh` to verify the data pipeline
5. Access the Databricks workspace URL shown in the output

For detailed instructions, see the sections below.
```

### Service Principal Section (add after Infrastructure Deployment)

```markdown
### Service Principal for Automation

This project uses an Azure Service Principal for automated management of Databricks resources:

1. **Create the Service Principal**:
   ```bash
   # Get subscription ID
   az account show --query id -o tsv
   
   # Create Service Principal
   az ad sp create-for-rbac --name databricks-niotv1-sp \
     --role Contributor \
     --scopes /subscriptions/YOUR_SUBSCRIPTION_ID
   ```

2. **Assign Workspace Owner role**:
   ```bash
   # Get workspace ID
   WORKSPACE_ID=$(az databricks workspace show \
     --name niotv1-dev-databricks \
     --resource-group niotv1-dev-rg \
     --query id -o tsv)
   
   # Assign Owner role
   az role assignment create \
     --assignee "YOUR_CLIENT_ID" \
     --role "Owner" \
     --scope "$WORKSPACE_ID"
   ```

3. **Update Terraform configuration** with SP credentials:
   - Edit `terraform/databricks-rbac/main.tf` to add SP credentials
   - The `deploy.sh --dbrbac` script automatically adds the correct host URL

This approach enables Infrastructure as Code (IaC) automation for Databricks without requiring interactive login.
```

### Scripts Section (add after prerequisites)

```markdown
## Utility Scripts

The project includes several utility scripts to simplify deployment and management:

### `deploy.sh`
A versatile deployment script that can:
- Deploy the entire infrastructure (`./deploy.sh`)
- Deploy only specific components (`./deploy.sh --infra`, `./deploy.sh --api`, `./deploy.sh --dbrbac`)
- Destroy all resources without redeploying (`./deploy.sh --destroy`)

The script includes intelligent waiting for Databricks initialization and handles tfvars configuration.

### `destroy_all.sh`
Performs a complete cleanup by:
- Destroying all Azure resources
- Removing all Terraform state files
- Cleaning Terraform working directories

### `show_resources.sh`
Lists all Azure resources created by this project:
- Resource groups and resources
- Storage accounts and containers
- App Services
- Databricks workspaces
- Service Principals and role assignments

### `test_datalake.sh`
Tests the full data pipeline:
- Sends test data to the API
- Verifies data is stored in the data lake
- Shows recent data records
```

### Troubleshooting Enhancements (add to troubleshooting section)

```markdown
### Storage Account Naming Issues

If you encounter conflicts with storage account names (which must be globally unique), modify the names in:
- `terraform/main.tf` for the config service storage
- `terraform/modules/ingest-api/main.tf` for the data lake storage

For example, change `raraid3iotdevstorage` to include your initials or a unique identifier.

### Script Execution Permissions

If you encounter permission issues running scripts:
```bash
# Make scripts executable
chmod +x *.sh
chmod +x scripts/*.sh
```

### Resource Cleanup Issues

If resources aren't properly destroyed:
1. Run `./show_resources.sh` to identify remaining resources
2. Try running `./deploy.sh --destroy` again
3. If issues persist, use the Azure Portal to manually delete resource groups
```
