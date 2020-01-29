#!/bin/bash

set -e

# CREATE VPC
# 20.0.0.0/16
# vpc-018c852ac00db6def

# CREATE subnet public
# 20.0.128.0/17
# eu-central-1a

# CREATE subnet private
# 20.0.0.0/17
# eu-central-1a

# CREATE internet GW + attach to VPC

# ADD route in public subnet routing table 0.0.0.0/0 -> internet GW

# CREATE NAT gateway in public SUBNET

# CREATE routing table (private routing table)
# ASSOCIATE routing table to private SUBNET

# ADD route in private subnet routing table 0.0.0.0/0 -> NAT GW

# ADD nano instance in public SUB, add Public IP
# CREATE security group (ext SSH in)

# aws ec2 run-instances
#   --image-id ami-xxxxxxxx
#   --count 1
#   --instance-type t2.micro
#   --key-name MyKeyPair
#   --security-group-ids sg-903004f8
#   --subnet-id subnet-6e7f829e

ip_it ()
{
  ret=""
  first="${1##*.*.*.}"
  for ((i = $first; i <= ${2##*.*.*.}; i++)); do
    ret="$ret ${1%%.$first}.$i"
  done
  echo $ret
}

SUBNET_ID=subnet-09237c4f6f5827c80
SECURITY_GROUP=sg-0c2d97256702fa05f

# NAME, ip#3, ip#4
generate_if_json ()
{
  echo "{
    \"Description\": \"$1\",
    \"Groups\": [
        \"$SECURITY_GROUP\"
    ],
    \"PrivateIpAddresses\": [" > interface.$1.json

  IS_PRIMARY="true"
  for ip in $(ip_it "$2.1" "$2.$3" ) ; do
    if [[ "$IS_PRIMARY" != "true" ]]; then
    echo "," >> interface.$1.json
    fi
    echo "        {
          \"Primary\": $IS_PRIMARY,
          \"PrivateIpAddress\": \"$ip\"
        }" >> interface.$1.json
    IS_PRIMARY="false"
  done
  echo "    ],
    \"SubnetId\": \"$SUBNET_ID\"
  }" >> interface.$1.json
}

generate_if_json vm1.if1 20.0.2 1
# aws ec2 create-network-interface --cli-input-json file://interface.vm1.if1.json
generate_if_json switch1.if1 20.0.3 1
# aws ec2 create-network-interface --cli-input-json file://interface.switch1.if1.json
generate_if_json switch1.if2 20.0.4 1
# aws ec2 create-network-interface --cli-input-json file://interface.switch1.if2.json
generate_if_json switch2.if1 20.0.5 1
# aws ec2 create-network-interface --cli-input-json file://interface.switch2.if1.json
generate_if_json switch2.if2 20.0.6 1
# aws ec2 create-network-interface --cli-input-json file://interface.switch2.if2.json
generate_if_json vm2.if1 20.0.7 1
aws ec2 create-network-interface --cli-input-json file://interface.vm2.if1.json
