# Waltr.Tech Infra

This repository contains the code and configuration used to manage the fleets of k8s and Terraform clusters managing the Waltr.Tech environment

Using a combination of Argo, Terraform, Vault and Kubernetes. 90% of all the configuration required for application and cluster installation is contained within this repo, while secrets are contained elsewhere.

## Dir use

**gitops** contains the Kubernetes code required for each k8s cluster application

**provision** contains the IAC and provision components needed to create and maintain a cluster

## Documentation

**docs** actually contains implementation details, not instructions on how to deploy this repo

## Ideology

Git as config, pushing is applying, push often, click less.

## Contributors

- rwaltr (Main Developer)
- gpzeke (accident-prone-documentation)
