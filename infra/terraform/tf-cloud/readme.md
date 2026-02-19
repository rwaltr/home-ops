# Terraform Cloud Configuration

Manages Terraform Cloud workspace configuration for this project.

## Overview

This workspace provisions and configures Terraform Cloud settings used by the other Terraform workspaces (cloudflare, backblaze).

## Usage

```bash
cd infra/terraform/tf-cloud
terraform init
terraform plan
terraform apply
```

## Migration Note

A Pulumi stub exists at `infra/pulumi/tf-cloud/` for eventual migration. The Terraform workspace remains active in the meantime.
