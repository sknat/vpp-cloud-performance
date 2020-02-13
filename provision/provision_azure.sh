#!/bin/bash

set -e

# Available configuration :
VMSIZE=
BASTIONSIZE=
LOCATION=
RESOURCE_GROUP=
NETWORK=
NET_SECURITY_GROUP=
SUBSCRIPTION=
SSH_KEYFILE=

SCRIPTDIR=$(dirname ${BASH_SOURCE[0]})
if [[ -f $SCRIPTDIR/provision_azure-conf.sh ]]; then
  source $SCRIPTDIR/provision_azure-conf.sh
fi

#
#
# This creates the following configuration
#  ___________              ___________              ___________              ____________
# |           |            |           |            |           |            |            |
# |          eth1         eth1         |            |          eth2         eth1          |
# |   20.0.2.64/26 ---- 20.0.2.10/32   |            |   20.0.7.10/32 ---- 20.0.7.64/26    |
# |  (20.0.2.11/32)  |     |           |            |           |        (20.0.7.11/32)   |
# |           |      |     | (20.0.4.10/32)    (20.0.4.12/32)   |            |            |
# |           |      |     |  20.0.4.64/26 ---- 20.0.4.128/26   |   ------- eth2          |
# |           |      |     |          eth2   |     eth1         |   |        |            |
# |    VM1    |      |     |    SW1    |     |      |    SW2    |   |    |--eth3     VM2  |
# |___________|      |     |___________|     |      |___________|   |    |   |____________|
#       |            |           |           |             |        |    |          |
#   20.0.1.4/32      |       20.0.1.6/32     |        20.0.1.7/32   |    |     20.0.1.5/32
#       eth0         |          eth0         |            eth0      |    |         eth0
#                    |                       |                      |    |
#                    |                       |____20.0.4.192/26_____|    |
#                    |                           (20.0.4.13/32)          |
#                    |______20.0.2.192/26________________________________|
#                          (20.0.2.13/32)
#
#
# To run the tests sync the repo on all machines using ./test/test sync <HOST>
#
# On VM1 : ./test/azure.sh vm1
# On VM2 : ./test/azure.sh vm2 [zero|one|two]     # zero/one/two being the number of hops from VM2 to VM1
# On SW1/SW2 :  ./test/azure.sh [linux|vpp|ipsec 1|ipsec 2]
#
# On VM1 : iperf3 -s -B 20.0.2.[64-127]
# On VM2 :
#  zero hop : iperf3 -c 20.0.2.[64-127] -B 20.0.2.[192-255]
#  one hop  : iperf3 -c 20.0.2.[64-127] -B 20.0.4.[192-255]
#  two hops : iperf3 -c 20.0.2.[64-127] -B 20.0.7.[64-127]

check_params ()
{
  if [[ "$VMSIZE" = "" ]] || \
    [[ "$BASTIONSIZE" = "" ]] || \
    [[ "$LOCATION" = "" ]] || \
    [[ "$RESOURCE_GROUP" = "" ]] || \
    [[ "$NETWORK" = "" ]] || \
    [[ "$NET_SECURITY_GROUP" = "" ]] || \
    [[ "$SUBSCRIPTION" = "" ]] || \
    [[ "$SSH_KEYFILE" = "" ]]; then
    echo "Please fill in required params"
    exit 1
  fi
}

create_route ()
{
  NAME=$1
  ADDR_PREFIX=$2
  RT_NAME=$3
  NXT_HOP=$4
  az network route-table route create                               \
    --subscription $SUBSCRIPTION                                    \
    --address-prefix $ADDR_PREFIX                                   \
    --name $RT_NAME                                                 \
    --next-hop-type VirtualAppliance                                \
    --resource-group $RESOURCE_GROUP                                \
    --route-table-name $NAME-route-table                            \
    --next-hop-ip-address $NXT_HOP
}

create_internet_route ()
{
  NAME=$1
  az network route-table route create                               \
    --subscription $SUBSCRIPTION                                    \
    --address-prefix 0.0.0.0/0                                      \
    --name internet                                                 \
    --next-hop-type Internet                                        \
    --resource-group $RESOURCE_GROUP                                \
    --route-table-name $NAME-route-table
}

create_subnet ()
{
  NAME=$1
  ADDR_PREFIX=$2
  az network route-table create                                     \
    --subscription $SUBSCRIPTION                                    \
    --resource-group $RESOURCE_GROUP                                \
    --location $LOCATION                                            \
    --name $NAME-route-table

  az network vnet subnet create                                     \
    --subscription $SUBSCRIPTION                                    \
    --resource-group $RESOURCE_GROUP                                \
    --name $NAME-subnet                                             \
    --address-prefixes $ADDR_PREFIX                                 \
    --vnet-name $NETWORK                                            \
    --network-security-group $NET_SECURITY_GROUP                    \
    --route-table $NAME-route-table
}

create_vm1_switch1_subnet ()
{
  create_subnet vm1-sw1 20.0.2.0/24
  create_route vm1-sw1 20.0.2.64/26 vm1-extra 20.0.2.11
  create_route vm1-sw1 20.0.7.64/26 vm2-two-hops 20.0.2.10
  create_route vm1-sw1 20.0.4.192/26 vm2-one-hop 20.0.2.10
  create_route vm1-sw1 20.0.2.192/26 vm2-no-hop 20.0.2.13
}

create_switch1_switch2_subnet ()
{
  create_subnet sw1-sw2 20.0.4.0/24
  create_route sw1-sw2 20.0.4.64/26 switch1 20.0.4.10
  create_route sw1-sw2 20.0.4.128/26 switch2 20.0.4.12
  create_route sw1-sw2 20.0.7.64/26 vm2-by-switch2 20.0.4.12
  create_route sw1-sw2 20.0.4.192/26 vm2 20.0.4.13
  create_route sw1-sw2 20.0.2.64/26 vm1-by-switch1 20.0.4.10
}

create_switch2_vm2_subnet ()
{
  create_subnet sw2-vm2 20.0.7.0/24
  create_route sw2-vm2 20.0.2.64/26 vm1 20.0.7.10
  create_route sw2-vm2 20.0.7.64/26 vm2 20.0.7.11
}


create_rg ()
{
  az group create                                                   \
    --subscription $SUBSCRIPTION                                    \
    --location $LOCATION                                            \
    --name $RESOURCE_GROUP

  az network vnet create                                            \
    --subscription $SUBSCRIPTION                                    \
    --name $NETWORK                                                 \
    --location $LOCATION                                            \
    --resource-group $RESOURCE_GROUP                                \
    --address-prefix 20.0.0.0/16                                    \
    --subnet-name management-subnet                                 \
    --subnet-prefix 20.0.1.0/24

  az network nsg create                                             \
    --subscription $SUBSCRIPTION                                    \
    --resource-group $RESOURCE_GROUP                                \
    --location $LOCATION                                            \
    --name $NET_SECURITY_GROUP
}

create_nic ()
{
  NICNAME=$1
  SUBNET=$2
  IP_IN_SUBNET=$3
  az network nic create                                             \
    --subscription $SUBSCRIPTION                                    \
    --location $LOCATION                                            \
    --resource-group $RESOURCE_GROUP                                \
    --name $NICNAME                                                 \
    --vnet-name $NETWORK                                            \
    --subnet $SUBNET                                                \
    --accelerated-networking true                                   \
    --private-ip-address $IP_IN_SUBNET                              \
    --public-ip-address ""                                          \
    --network-security-group $NET_SECURITY_GROUP
}

create_bastion ()
{

  az vm create                                                      \
    --subscription $SUBSCRIPTION                                    \
    --location $LOCATION                                            \
    --name bastion                                                  \
    --size $BASTIONSIZE                                             \
    --resource-group $RESOURCE_GROUP                                \
    --authentication-type ssh                                       \
    --admin-username ubuntu                                         \
    --ssh-key-values $SSH_KEYFILE                                   \
    --image Canonical:UbuntuServer:18.04-LTS:latest                 \
    --subnet management-subnet                                      \
    --vnet-name $NETWORK
}

create_machine ()
{
  NAME=$1
  IP_IN_SUBNET=$2
  NICNAME=$NAME-mngmt-if
  create_nic $NAME-mngmt-if management-subnet $IP_IN_SUBNET

  az vm create                                                      \
    --subscription $SUBSCRIPTION                                    \
    --location $LOCATION                                            \
    --name $NAME                                                    \
    --size $VMSIZE                                                  \
    --resource-group $RESOURCE_GROUP                                \
    --authentication-type ssh                                       \
    --admin-username ubuntu                                         \
    --ssh-key-values $SSH_KEYFILE                                   \
    --image Canonical:UbuntuServer:18.04-LTS:latest                 \
    --nics $NICNAME ${@:3}                                          \
    --no-wait

}

print_ssh_commands ()
{
  EXTIP=$(az vm list-ip-addresses -g $RESOURCE_GROUP -n bastion | grep ipAddress | cut -d '"' -f 4)
  echo "To ssh to the machines use :"
  echo "VM1 :: ssh ubuntu@20.0.1.4 -i $SSH_KEYFILE -o ProxyCommand=\"ssh -W %h:%p ubuntu@$EXTIP -i $SSH_KEYFILE\""
  echo "SW1 :: ssh ubuntu@20.0.1.6 -i $SSH_KEYFILE -o ProxyCommand=\"ssh -W %h:%p ubuntu@$EXTIP -i $SSH_KEYFILE\""
  echo "SW2 :: ssh ubuntu@20.0.1.7 -i $SSH_KEYFILE -o ProxyCommand=\"ssh -W %h:%p ubuntu@$EXTIP -i $SSH_KEYFILE\""
  echo "VM2 :: ssh ubuntu@20.0.1.5 -i $SSH_KEYFILE -o ProxyCommand=\"ssh -W %h:%p ubuntu@$EXTIP -i $SSH_KEYFILE\""
}

create_all ()
{
  create_rg
  create_vm1_switch1_subnet
  create_switch1_switch2_subnet
  create_switch2_vm2_subnet

  create_nic vm1-if1 vm1-sw1-subnet 20.0.2.11
  create_nic sw1-if1 vm1-sw1-subnet 20.0.2.10
  create_nic sw1-if2 sw1-sw2-subnet 20.0.4.10
  create_nic sw2-if1 sw1-sw2-subnet 20.0.4.12
  create_nic vm2-if1 sw2-vm2-subnet 20.0.7.11
  create_nic vm2-if2 sw1-sw2-subnet 20.0.4.13
  create_nic vm2-if3 vm1-sw1-subnet 20.0.2.13

  create_machine vm1 20.0.1.4 vm1-if1
  create_machine vm2 20.0.1.5 vm2-if1 vm2-if2 vm2-if3
  create_machine switch1 20.0.1.6 sw1-if1 sw1-if2
  create_machine switch2 20.0.1.7 sw2-if1 sw2-if2

  create_bastion

  print_ssh_commands
}

if [[ "$1" = "create" ]]; then
  check_params
  create_all
elif [[ "$1" = "ssh" ]]; then
  check_params
  print_ssh_commands
else
  echo "Usage:"
  echo "./provision_azure.sh create"
  echo "./provision_azure.sh ssh"
fi



