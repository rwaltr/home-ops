# Waltr.Tech Infra

This repository contians the code and configuration used to manged the fleets of k8s and Terraform clusters managing the Waltr.Tech envioment. 

Using a combination of Argo, Terraform, Vault and Kubernetes. 90% of all the configuration required for application and cluster installation is contained within this repo, while secrets are contained elsewhere. 

## Dir use


**gitops** contains the kubernetes code required for each k8s cluster application

**cluster** contains the IAC and terraform config to provision and maintain a cluster

**documentions** contains the documenttion to interact and manage the clusters

**legacy** old code from the old age

**.archive** the app graveyard


## Idealogy 

Git as config, pushing is applying, push often, click less.
