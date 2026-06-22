# stacks/dev/main.tf
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
  backend "azurerm" {}    # config supplied via -backend-config=backend.hcl
}

provider "azurerm" {
  features {}
  use_oidc        = true     # tell the provider to expect OIDC auth in CI
  subscription_id = var.subscription_id
}

variable "subscription_id" { type = string }
variable "location"        { type = string, default = "eastus" }
variable "env"             { type = string, default = "dev" }

resource "azurerm_resource_group" "this" {
  name     = "rg-sapdemo-${var.env}"
  location = var.location
  tags     = { env = var.env, owner = "platform-team", cost-center = "ist-platform" }
}

module "storage" {
  source              = "../../modules/storage-account"
  name                = "stsapdemo${var.env}${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tags                = azurerm_resource_group.this.tags
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}