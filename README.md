# Waltr.Tech Infra

This repository contains the code and configuration used to manged the fleets of k8s and Terraform clusters managing the Waltr.Tech environment. 

Using a combination of Argo, Terraform, Vault and Kubernetes. 90% of all the configuration required for application and cluster installation is contained within this repo, while secrets are contained elsewhere. 

## Dir use


**gitops** contains the Kubernetes code required for each k8s cluster application

**cluster** contains the IAC and terraform config to provision and maintain a cluster

**legacy** old code from the old age

## Documentation

Documentation is included along the folders of the environment

## Ideology 

Git as config, pushing is applying, push often, click less.
