#!/bin/bash
az vm create                                                      \
  --location eastus                                               \
  --subnet mngmt                                                  \
  --vnet-name nsk.network                                         \
  --subscription 0c27af66-f0dd-4f0e-bc8e-25513d4faacc             \
  --name nsk-vm1-f72                                              \
  --size Standard_F72s_v2                                         \
  --resource-group nsk.resources                                  \
  --accelerated-networking true                                   \
  --authentication-type ssh                                       \
  --admin-username ubuntu                                         \
  --ssh-key-values /Users/nskrzypc/.ssh/nskrzypc-azure.pem.pub    \
  --private-ip-address 20.0.1.14                                  \
  --os-type linux                                                 \
  --image Canonical:UbuntuServer:16.04-LTS:latest

