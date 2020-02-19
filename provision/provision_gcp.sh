#!/bin/bash

set -e

PROJECT=
REGION=
ZONE=
PREFIX=
IMAGE=
VM_SIZE=
SWITCH_SIZE=

SCRIPTDIR=$(dirname ${BASH_SOURCE[0]})
if [[ -f $SCRIPTDIR/provision_gcp-conf.sh ]]; then
  source $SCRIPTDIR/provision_gcp-conf.sh
fi

#
#
# This creates the following configuration
#  ___________              ___________              ___________              ____________
# |           |            |           |            |           |            |            |
# |          eth1         eth1         |            |          eth2         eth1          |
# |   10.0.2.64/26 ---- 10.0.2.10/32   |            |   10.0.7.10/32 ---- 10.0.7.64/26    |
# |  (10.0.2.11/32)  |     |           |            |           |        (10.0.7.11/32)   |
# |           |      |     | (10.0.4.10/32)    (10.0.4.12/32)   |            |            |
# |           |      |     |  10.0.4.64/26 ---- 10.0.4.128/26   |   ------- eth2          |
# |           |      |     |          eth2   |     eth1         |   |        |            |
# |    VM1    |      |     |    SW1    |     |      |    SW2    |   |    |--eth3     VM2  |
# |___________|      |     |___________|     |      |___________|   |    |   |____________|
#       |            |           |           |             |        |    |          |
#   10.0.1.4/32      |       10.0.1.6/32     |        10.0.1.7/32   |    |     10.0.1.5/32
#       eth0         |          eth0         |            eth0      |    |         eth0
#                    |                       |                      |    |
#                    |                       |____10.0.4.192/26_____|    |
#                    |                           (10.0.4.13/32)          |
#                    |______10.0.2.192/26________________________________|
#                          (10.0.2.13/32)
#
#
# To run the tests sync the repo on all machines using ./test/test sync <HOST>
#
# On VM1 : ./test/azure.sh vm1
# On VM2 : ./test/azure.sh vm2 [zero|one|two]     # zero/one/two being the number of hops from VM2 to VM1
# On SW1/SW2 :  ./test/azure.sh [linux|vpp|ipsec 1|ipsec 2]
#
# On VM1 : iperf3 -s -B 10.0.2.[64-127]
# On VM2 :
#  zero hop : iperf3 -c 10.0.2.[64-127] -B 10.0.2.[192-255]
#  one hop  : iperf3 -c 10.0.2.[64-127] -B 10.0.4.[192-255]
#  two hops : iperf3 -c 10.0.2.[64-127] -B 10.0.7.[64-127]

check_params ()
{
  if [[ "$PROJECT" = "" ]] || \
    [[ "$REGION" = "" ]] || \
    [[ "$ZONE" = "" ]] || \
    [[ "$PREFIX" = "" ]] || \
    [[ "$IMAGE" = "" ]]; then
    echo "Please fill in required params"
    exit 1
  fi
}

create_vm ()
{
  NAME=$1
  SIZE=$2
  gcloud compute \
    --project=$PROJECT \
    instances create \
    $PREFIX-$NAME \
    --zone=$ZONE \
    --machine-type=$SIZE \
    --network-tier=PREMIUM \
    --can-ip-forward \
    --image=$IMAGE \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=10GB \
    --boot-disk-type=pd-standard \
    --boot-disk-device-name=$PREFIX-$NAME \
    --min-cpu-platform="Intel Skylake" \
    --reservation-affinity=any ${@:3}
}

create_vm1 ()
{
  create_vm vm1 $VM_SIZE \
    --network-interface subnet=$PREFIX-mngmt-subnet,private-network-ip=10.0.1.4 \
    --network-interface subnet=$PREFIX-vm1-sw1-subnet,private-network-ip=10.0.2.11,no-address
}

create_sw1 ()
{
  create_vm sw1 $VM_SIZE \
    --network-interface subnet=$PREFIX-mngmt-subnet,private-network-ip=10.0.1.6 \
    --network-interface subnet=$PREFIX-vm1-sw1-subnet,private-network-ip=10.0.2.10,no-address \
    --network-interface subnet=$PREFIX-sw1-sw2-subnet,private-network-ip=10.0.4.10,no-address
}

create_sw2 ()
{
  create_vm sw2 $SWITCH_SIZE \
    --network-interface subnet=$PREFIX-mngmt-subnet,private-network-ip=10.0.1.7 \
    --network-interface subnet=$PREFIX-sw1-sw2-subnet,private-network-ip=10.0.4.12,no-address \
    --network-interface subnet=$PREFIX-sw2-vm2-subnet,private-network-ip=10.0.7.10,no-address
}

create_vm2 ()
{
  create_vm vm2 $SWITCH_SIZE \
    --network-interface subnet=$PREFIX-mngmt-subnet,private-network-ip=10.0.1.5 \
    --network-interface subnet=$PREFIX-sw2-vm2-subnet,private-network-ip=10.0.7.11,no-address \
    --network-interface subnet=$PREFIX-sw1-sw2-subnet,private-network-ip=10.0.4.13,no-address \
    --network-interface subnet=$PREFIX-vm1-sw1-subnet,private-network-ip=10.0.2.13,no-address
}

create_bastion ()
{
  create_vm bastion f1-micro \
    --network-interface subnet=$PREFIX-mngmt-subnet,private-network-ip=10.0.1.9
}

create_firewall_rule ()
{
  NAME=$1
  NETNAME=$2
  IPRANGE=$3
  gcloud compute \
    --project=$PROJECT \
    firewall-rules create \
    $PREFIX-$NETNAME-$NAME-rule \
    --direction=INGRESS \
    --priority=1000 \
    --network=$PREFIX-$NETNAME-net \
    --action=ALLOW \
    --rules=all \
    --source-ranges=$IPRANGE ${@:4}
}

create_subnet ()
{
  NAME=$1
  IPRANGE=$2
  gcloud compute \
    --project=$PROJECT \
    networks create \
    $PREFIX-$NAME-net \
    --subnet-mode=custom
  gcloud compute \
    --project=$PROJECT \
    networks subnets create \
    $PREFIX-$NAME-subnet \
    --network=$PREFIX-$NAME-net \
    --region=$REGION \
    --range=$IPRANGE
}

create_route ()
{
  NAME=$1
  ADDR_PREFIX=$2
  RT_NAME=$3
  NXT_HOP=$4
  gcloud compute routes create \
    $PREFIX-$NAME-route-$RT_NAME \
    --project=$PROJECT \
    --network=$PREFIX-$NAME-net \
    --priority=1000 \
    --destination-range=$ADDR_PREFIX \
    --next-hop-address=$NXT_HOP
}

create_mngmt_subnet ()
{
  create_subnet mngmt 10.0.1.0/24
  create_firewall_rule internal mngmt 10.0.1.0/24
  create_firewall_rule ssh-in mngmt 0.0.0.0/0 --rules=tcp:22
}

create_vm1_switch1_subnet ()
{
  create_subnet vm1-sw1 10.0.2.0/26
  create_route vm1-sw1 10.0.2.64/26 vm1-extra 10.0.2.11
  create_route vm1-sw1 10.0.7.64/26 vm2-two-hops 10.0.2.10
  create_route vm1-sw1 10.0.4.192/26 vm2-one-hop 10.0.2.10
  create_route vm1-sw1 10.0.2.192/26 vm2-no-hop 10.0.2.13
  create_firewall_rule internal vm1-sw1 10.0.0.0/16
}

create_switch1_switch2_subnet ()
{
  create_subnet sw1-sw2 10.0.4.0/26
  create_route sw1-sw2 10.0.4.64/26 switch1 10.0.4.10
  create_route sw1-sw2 10.0.4.128/26 switch2 10.0.4.12
  create_route sw1-sw2 10.0.7.64/26 vm2-by-switch2 10.0.4.12
  create_route sw1-sw2 10.0.4.192/26 vm2 10.0.4.13
  create_route sw1-sw2 10.0.2.64/26 vm1-by-switch1 10.0.4.10
  create_firewall_rule internal sw1-sw2 10.0.0.0/16
}

create_switch2_vm2_subnet ()
{
  create_subnet sw2-vm2 10.0.7.0/26
  create_route sw2-vm2 10.0.2.64/26 vm1 10.0.7.10
  create_route sw2-vm2 10.0.7.64/26 vm2 10.0.7.11
  create_firewall_rule internal sw2-vm2 10.0.0.0/16
}

create_all ()
{
  create_mngmt_subnet
  create_vm1_switch1_subnet
  create_switch1_switch2_subnet
  create_switch2_vm2_subnet
  create_vm1
  create_vm2
  create_sw1
  create_sw2
  create_bastion
}

if [[ "$1" = "create" ]]; then
  check_params
  create_all
elif [[ "$1" = "ssh" ]]; then
  check_params
else
  echo "Usage:"
  echo "./provision_azure.sh create"
  echo "./provision_azure.sh ssh"
fi
