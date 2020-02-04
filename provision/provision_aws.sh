#!/bin/bash

set -e

# Available configuration :
AVAILABILITY_ZONE=
NAT_GW_IP_ALLOC_ID=
INSTANCE_AMI=
VM_INSTANCE_AMI=
SWITCH_INSTANCE_AMI=
KEYPAIR_NAME=
NAME_PREFIX=
VM_SIZE=
SWITCH_SIZE=

SCRIPTDIR=$(dirname ${BASH_SOURCE[0]})
if [ -f $SCRIPTDIR/provision_aws-conf.sh ]; then
  source $SCRIPTDIR/provision_aws-conf.sh
fi

LOGDIR=$SCRIPTDIR/aws-log/
mkdir -p $LOGDIR

#
# This creates the following configuration
#  ___________              ___________              ___________              ____________
# |           |            |           |            |           |            |            |
# |          ens6         ens6         |            |          ens7         ens6          |
# |   20.0.2.0/24 ----- 20.0.3.0/24    |            |     20.0.6.0/24 ---- 20.0.7.0/24    |
# |           |            |           |            |           |            |            |
# |           |            |  20.0.4.0/24 ------- 20.0.5.0/24   |            |            |
# |           |            |          ens7         ens6         |            |            |
# |    VM1    |            |    SW1    |            |    SW2    |            |     VM2    |
# |___________|            |___________|            |___________|            |____________|
#       |                        |                         |                        |
#   20.0.1.1/32              20.0.1.2/32              20.0.1.3/32              20.0.1.4/32
#       ens5                    ens5                      ens5                     ens5
#
# To run the tests sync the repo on all machines using ./test/test sync <HOST>
#
# On VM1 : ./test/aws.sh vm1
# On VM2 : ./test/aws.sh vm2 [zero|one|two]     # zero/one/two being the number of hops from VM2 to VM1
# On SW1/SW2 :  ./test/aws.sh [linux|pmd|vpp|ipsec 1|ipsec 2]
#
# On VM1 : iperf3 -s -B 20.0.2.[64-127]
# On VM2 :
#  zero hop : iperf3 -c 20.0.2.[64-127] -B 20.0.2.[192-255]
#  one hop  : iperf3 -c 20.0.2.[64-127] -B 20.0.4.[192-255]
#  two hops : iperf3 -c 20.0.2.[64-127] -B 20.0.7.[64-127]

check_params ()
{
  if [[ "$AVAILABILITY_ZONE" = "" ]] || \
    [[ "$NAT_GW_IP_ALLOC_ID" = "" ]] || \
    [[ "$INSTANCE_AMI" = "" ]] || \
    [[ "$VM_INSTANCE_AMI" = "" ]] || \
    [[ "$SWITCH_INSTANCE_AMI" = "" ]] || \
    [[ "$KEYPAIR_NAME" = "" ]] || \
    [[ "$VM_SIZE" = "" ]] || \
    [[ "$SWITCH_SIZE" = "" ]]; then
    echo "Please fill in required params"
    exit 1
  fi
}

create_vpc ()
{
  aws ec2 create-vpc \
    --cidr-block 20.0.0.0/16 > $LOGDIR/create-vpc.log
  VPCID=$(cat $LOGDIR/create-vpc.log | jq -r .Vpc.VpcId)

  aws ec2 create-subnet \
    --availability-zone $AVAILABILITY_ZONE \
    --vpc-id $VPCID \
    --cidr-block 20.0.128.0/17 > $LOGDIR/create-subnet-public.log
  PUBLIC_SUBNET_ID=$(cat $LOGDIR/create-subnet-public.log | jq -r .Subnet.SubnetId)

  aws ec2 create-subnet \
    --availability-zone $AVAILABILITY_ZONE \
    --vpc-id $VPCID \
    --cidr-block 20.0.0.0/17 > $LOGDIR/create-subnet-private.log
  PRIVATE_SUBNET_ID=$(cat $LOGDIR/create-subnet-private.log | jq -r .Subnet.SubnetId)

  aws ec2 create-internet-gateway > $LOGDIR/create-internet-gateway.log
  INTERNET_GW_ID=$(cat $LOGDIR/create-internet-gateway.log | jq -r .InternetGateway.InternetGatewayId)
  aws ec2 attach-internet-gateway \
    --internet-gateway-id $INTERNET_GW_ID \
    --vpc-id $VPCID > $LOGDIR/attach-internet-gateway.log

  aws ec2 create-route-table \
    --vpc-id $VPCID > $LOGDIR/create-route-table-private.log
  PRIVATE_RT_ID=$(cat $LOGDIR/create-route-table-private.log | jq -r .RouteTable.RouteTableId)

  aws ec2 associate-route-table \
    --subnet-id $PRIVATE_SUBNET_ID \
    --route-table-id $PRIVATE_RT_ID > $LOGDIR/associate-route-table-private.log

  aws ec2 create-route-table \
    --vpc-id $VPCID > $LOGDIR/create-route-table-public.log
  PUBLIC_RT_ID=$(cat $LOGDIR/create-route-table-public.log | jq -r .RouteTable.RouteTableId)

  aws ec2 associate-route-table \
    --subnet-id $PUBLIC_SUBNET_ID \
    --route-table-id $PUBLIC_RT_ID > $LOGDIR/associate-route-table-public.log

  aws ec2 create-route \
    --route-table-id $PUBLIC_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id $INTERNET_GW_ID > $LOGDIR/create-route-igw.log

  aws ec2 create-nat-gateway \
    --allocation-id $NAT_GW_IP_ALLOC_ID \
    --subnet-id $PUBLIC_SUBNET_ID > $LOGDIR/create-nat-gateway.log
  NAT_GW_ID=$(cat $LOGDIR/create-nat-gateway.log | jq -r .NatGateway.NatGatewayId)

  aws ec2 create-route \
    --route-table-id $PRIVATE_RT_ID \
    --destination-cidr-block 0.0.0.0/0 \
    --nat-gateway-id $NAT_GW_ID > $LOGDIR/create-route-nat-gw.log

  aws ec2 create-security-group \
    --description "Only ssh" \
    --vpc-id $VPCID \
    --group-name "${NAME_PREFIX}-ssh-sg" > $LOGDIR/create-security-group-public.log
  PUBLIC_SG_ID=$(cat $LOGDIR/create-security-group-public.log | jq -r .GroupId)

  aws ec2 create-security-group \
    --description "Internal" \
    --vpc-id $VPCID \
    --group-name "${NAME_PREFIX}-internal-sg" > $LOGDIR/create-security-group-private.log
  PRIVATE_SG_ID=$(cat $LOGDIR/create-security-group-private.log | jq -r .GroupId)

  aws ec2 authorize-security-group-ingress \
    --group-id $PUBLIC_SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 > $LOGDIR/authorize-security-group-ingress-public.log

  aws ec2 authorize-security-group-ingress \
    --group-id $PRIVATE_SG_ID \
    --protocol tcp \
    --port 22 \
    --source-group $PUBLIC_SG_ID > $LOGDIR/authorize-security-group-ingress-private-ssh.log

  aws ec2 authorize-security-group-ingress \
    --group-id $PRIVATE_SG_ID \
    --protocol all \
    --source-group $PRIVATE_SG_ID > $LOGDIR/authorize-security-group-ingress-private.log

}

create_bastion ()
{
  PUBLIC_SUBNET_ID=$(cat $LOGDIR/create-subnet-public.log | jq -r .Subnet.SubnetId)
  PUBLIC_SG_ID=$(cat $LOGDIR/create-security-group-public.log | jq -r .GroupId)
  aws ec2 run-instances \
    --image-id $INSTANCE_AMI \
    --count 1 \
    --instance-type t2.nano \
    --key-name $KEYPAIR_NAME \
    --security-group-ids $PUBLIC_SG_ID \
    --subnet-id $PUBLIC_SUBNET_ID \
    --associate-public-ip-address \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_PREFIX}bastion}]"
}

create_private_instance ()
{
  SIZE=$1
  NAME=$2
  IP=$3
  AMI=${4-$INSTANCE_AMI}
  PRIVATE_SUBNET_ID=$(cat $LOGDIR/create-subnet-private.log | jq -r .Subnet.SubnetId)
  PRIVATE_SG_ID=$(cat $LOGDIR/create-security-group-private.log | jq -r .GroupId)
  aws ec2 run-instances \
    --image-id $AMI \
    --count 1 \
    --instance-type $SIZE \
    --key-name $KEYPAIR_NAME \
    --security-group-ids $PRIVATE_SG_ID \
    --private-ip-address $IP \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${NAME_PREFIX}${NAME}}]" \
    --subnet-id $PRIVATE_SUBNET_ID > $LOGDIR/create-instance-$NAME.log
}

create_nic ()
{
  NAME=$1
  IP=$2
  PRIVATE_SG_ID=$(cat $LOGDIR/create-security-group-private.log | jq -r .GroupId)
  PRIVATE_SUBNET_ID=$(cat $LOGDIR/create-subnet-private.log | jq -r .Subnet.SubnetId)
  aws ec2 create-network-interface \
    --description $NAME \
    --groups $PRIVATE_SG_ID \
    --private-ip-address $IP \
    --subnet-id $PRIVATE_SUBNET_ID > $LOGDIR/create-nic-$NAME.log

  NIC_ID=$(cat $LOGDIR/create-nic-$NAME.log | jq -r .NetworkInterface.NetworkInterfaceId)
  aws ec2 modify-network-interface-attribute \
    --network-interface-id $NIC_ID \
    --no-source-dest-check
}

attach_nic ()
{
  NIC_NAME=$1
  INST_NAME=$2
  IDX=$3
  NIC_ID=$(cat $LOGDIR/create-nic-$NIC_NAME.log | jq -r .NetworkInterface.NetworkInterfaceId)
  INST_ID=$(cat $LOGDIR/create-instance-$INST_NAME.log | jq -r '.Instances[0].InstanceId')
  aws ec2 attach-network-interface \
    --device-index $IDX \
    --instance-id $INST_ID \
    --network-interface-id $NIC_ID > $LOGDIR/attach-network-interface-$NIC_NAME-$NIC.log
}

create_vm ()
{
  # VM1
  create_nic vm1-if1 20.0.2.1
  create_private_instance $VM_SIZE vm1 20.0.1.1 $VM_INSTANCE_AMI
  # VM2
  create_nic vm2-if1 20.0.7.1
  create_private_instance $VM_SIZE vm2 20.0.1.4 $VM_INSTANCE_AMI

  VM1_ID=$(cat $LOGDIR/create-instance-vm1.log | jq -r '.Instances[0].InstanceId')
  VM2_ID=$(cat $LOGDIR/create-instance-vm2.log | jq -r '.Instances[0].InstanceId')
  aws ec2 wait instance-running --instance-ids $VM1_ID $VM2_ID
  attach_nic vm1-if1 vm1 1
  attach_nic vm2-if1 vm2 1
}

create_switches ()
{
  # Switch 1
  create_nic sw1-if1 20.0.3.1
  create_nic sw1-if2 20.0.4.1
  create_private_instance $SWITCH_SIZE sw1 20.0.1.2 $SWITCH_INSTANCE_AMI
  # Switch 2
  create_nic sw2-if1 20.0.5.1
  create_nic sw2-if2 20.0.6.1
  create_private_instance $SWITCH_SIZE sw2 20.0.1.3 $SWITCH_INSTANCE_AMI

  SW1_ID=$(cat $LOGDIR/create-instance-sw1.log | jq -r '.Instances[0].InstanceId')
  SW2_ID=$(cat $LOGDIR/create-instance-sw2.log | jq -r '.Instances[0].InstanceId')
  aws ec2 wait instance-running --instance-ids $SW1_ID $SW2_ID
  attach_nic sw1-if1 sw1 1
  attach_nic sw1-if2 sw1 2
  attach_nic sw2-if1 sw2 1
  attach_nic sw2-if2 sw2 2
}

if [[ "$1" = "create" ]]; then
  check_params
  create_vpc
  create_bastion
  create_vm
  create_switches
else
  echo "Usage:"
  echo "./provision_azure.sh create"
  echo "./provision_azure.sh ssh"
fi






