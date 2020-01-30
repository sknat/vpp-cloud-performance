#!/bin/bash

VMSIZE=Standard_F72s_v2

create_machine ()
{
  NAME=$1 # e.g. vm1-f72
  IP_IN_SUBNET=$2 # e.g. 24
  NICNAME=nsk-$NAME-mngmt-if
  az network nic create                                             \
    --location eastus                                               \
    --resource-group nsk.resources                                  \
    --name $NICNAME                                                 \
    --vnet-name nsk.network                                         \
    --subnet mngmt                                                  \
    --accelerated-networking true                                   \
    --private-ip-address 20.0.1.$IP_IN_SUBNET                       \
    --public-ip-address ""                                          \
    --network-security-group nsk-vm1-nsg

  az vm create                                                      \
    --location eastus                                               \
    --subscription 0c27af66-f0dd-4f0e-bc8e-25513d4faacc             \
    --name nsk-$NAME                                                \
    --size $VMSIZE                                                  \
    --resource-group nsk.resources                                  \
    --authentication-type ssh                                       \
    --admin-username ubuntu                                         \
    --ssh-key-values /Users/nskrzypc/.ssh/nskrzypc-azure.pem.pub    \
    --image Canonical:UbuntuServer:18.04-LTS:latest                 \
    --nics $NICNAME

}

move_nics ()
{
  SRC_VM=$1
  DST_VM=$2
  az vm nic remove -g nsk.resources --vm-name $SRC_VM --nics ${@:3}
  az vm nic add -g nsk.resources --vm-name $DST_VM --nics ${@:3}
}

# create_machine vm2-f72 25
move_nics nsk-vm1-f72 nsk-vm1 nsk-vm1-if1
move_nics nsk-vm2-f72 nsk-vm2 nsk-vm2-if1 nsk-vm2-if2 vm2-if3


