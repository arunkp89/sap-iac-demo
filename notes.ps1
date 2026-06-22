# Variables — change to suit
$SUB_ID    = (az account show --query id -o tsv)
$LOCATION  = "eastus"
$TFRG      = "rg-tfstate-shared"
$TFSA      = "sttfstate$(Get-Random -Maximum 999999)"   # must be globally unique
$TFCONT    = "tfstate"

# 1. Resource group
az group create --name $TFRG --location $LOCATION

# 2. Storage account with versioning + soft delete (your safety net against corruption)
az storage account create `
  --name $TFSA --resource-group $TFRG --location $LOCATION `
  --sku Standard_ZRS --min-tls-version TLS1_2 `
  --allow-blob-public-access false --kind StorageV2

az storage account blob-service-properties update `
  --account-name $TFSA --resource-group $TFRG `
  --enable-versioning true --enable-delete-retention true --delete-retention-days 30 `
  --enable-container-delete-retention true --container-delete-retention-days 30

# 3. Container
az storage container create --name $TFCONT --account-name $TFSA --auth-mode login

# 4. Save backend config — Terraform will read this via -backend-config=backend.hcl
@"
resource_group_name  = "$TFRG"
storage_account_name = "$TFSA"
container_name       = "$TFCONT"
key                  = "dev/terraform.tfstate"
use_oidc             = true
use_azuread_auth     = true
"@ | Out-File -Encoding ascii stacks\dev\backend.hcl

Write-Host "Backend SA: $TFSA (save this; you'll need it again)"

####################################
#### Azure App Registration ########

$GH_ORG  = "arunkp89"
$GH_REPO = "sap-iac-demo"

# Create three User-Assigned Managed Identities — one per env
foreach ($env in @("dev","staging","prod")) {
  az identity create `
    --name "id-sapdemo-$env" `
    --resource-group $TFRG `
    --location $LOCATION

  $clientId = (az identity show -n "id-sapdemo-$env" -g $TFRG --query clientId -o tsv)
  $principalId = (az identity show -n "id-sapdemo-$env" -g $TFRG --query principalId -o tsv)

  # Federated credential — TRUST ONLY THIS REPO + THIS ENVIRONMENT
  az identity federated-credential create `
    --name "github-$env" `
    --identity-name "id-sapdemo-$env" `
    --resource-group $TFRG `
    --issuer "https://token.actions.githubusercontent.com" `
    --subject "repo:${GH_ORG}/${GH_REPO}:environment:$env" `
    --audiences "api://AzureADTokenExchange"

  # RBAC — Contributor on the subscription. In prod tighten to specific RG.
  az role assignment create `
    --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
    --role "Contributor" --scope "/subscriptions/$SUB_ID"

  # Storage perms on the state backend — needed for Terraform's state reads/writes
  az role assignment create `
    --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" `
    --scope "/subscriptions/$SUB_ID/resourceGroups/$TFRG/providers/Microsoft.Storage/storageAccounts/$TFSA"

  Write-Host "$env client-id: $clientId"
}

$TENANT_ID = (az account show --query tenantId -o tsv)
Write-Host "Tenant: $TENANT_ID"
Write-Host "Subscription: $SUB_ID"


####################################
#### Create Branch Protection ########
# 1. Create the repo and push the bootstrap
git add .
git commit -S -m "bootstrap: repo scaffold, .gitignore, modules, stacks"
gh repo create "$GH_REPO" --private --source=. --remote=origin --push

# 2. Set org/repo-level Actions defaults: read-only token by default
gh api -X PUT "repos/$GH_ORG/$GH_REPO/actions/permissions/workflow" `
  -f default_workflow_permissions=read `
  -F can_approve_pull_request_reviews=false

# 3. Branch protection on main — require PR, status checks, signed commits, no force-push
$branchProtection = @'
{
  "required_status_checks": { "strict": true, "contexts": [] },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_signatures": true
}
'@
$branchProtection | gh api -X PUT "repos/$GH_ORG/$GH_REPO/branches/main/protection" --input -

# 4. Create one GitHub environment per Azure identity
foreach ($env in @("dev","staging","prod")) {
  gh api -X PUT "repos/$GH_ORG/$GH_REPO/environments/$env"
}

# 5. Add per-env reviewer rules on prod (require approval before apply runs)
#    Replace 12345 with your GitHub user ID (gh api user --jq .id)
$MY_USER_ID = (gh api user --jq .id)
$prodEnv = @"
{
  "wait_timer": 0,
  "reviewers": [ { "type": "User", "id": $MY_USER_ID } ],
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
"@
$prodEnv | gh api -X PUT "repos/$GH_ORG/$GH_REPO/environments/prod" --input -

# 6. Per-environment variables (non-secret — client IDs of the MIs are not sensitive)
foreach ($env in @("dev","staging","prod")) {
  $clientId = (az identity show -n "id-sapdemo-$env" -g $TFRG --query clientId -o tsv)
  gh variable set AZURE_CLIENT_ID       -e $env -b "$clientId"
  gh variable set AZURE_TENANT_ID       -e $env -b "$TENANT_ID"
  gh variable set AZURE_SUBSCRIPTION_ID -e $env -b "$SUB_ID"
}

# 7. CODEOWNERS — required for "require code owner reviews" branch policy
@"
*                          @$GH_ORG
.github/workflows/         @$GH_ORG
stacks/prod/               @$GH_ORG
modules/                   @$GH_ORG
"@ | Out-File -Encoding utf8 .github\CODEOWNERS

git checkout -b chore/codeowners
git add .github\CODEOWNERS
git commit -S -m "chore: add CODEOWNERS"
git push -u origin chore/codeowners

gh pr create --base main --head chore/codeowners `
  --title "chore: add CODEOWNERS" `
  --body  "Adds CODEOWNERS so the require-code-owner-reviews rule has owners to call." `
  --fill-first
# After approvals + checks:
gh pr merge --squash --delete-branch