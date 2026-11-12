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

This workspace stays on Terraform; OpenTofu is the intended future direction.
