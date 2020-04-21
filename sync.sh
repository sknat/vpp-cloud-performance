#!/bin/bash

source $( dirname "${BASH_SOURCE[0]}" )/shared.sh

_ssh_cmd ()
{
  ssh \
    -i $LOCAL_IDENTITY_FILE \
    -o ProxyCommand="ssh -W %h:%p $USERNAME@$BASTION_IP -i $LOCAL_IDENTITY_FILE" \
    -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" \
    $USERNAME@$1 ${@:2}
}

sync ()
{
  rsync -avz                      \
    -e "ssh -i $LOCAL_IDENTITY_FILE -o ProxyCommand=\"ssh -W %h:%p $USERNAME@$BASTION_IP -i $LOCAL_IDENTITY_FILE\" -o \"StrictHostKeyChecking no\" -o \"UserKnownHostsFile /dev/null\"" \
    --exclude=currentrun          \
    --exclude=results             \
    --exclude=provision           \
    --exclude=.*                  \
    --include=conf/orch           \
    --include=conf/$1             \
    --exclude=conf/*              \
    $SCRIPTDIR/                   \
    $LOCAL_IDENTITY_FILE          \
    $USERNAME@$VM2_MANAGEMENT_IP:~/test/
  _ssh_cmd $VM2_MANAGEMENT_IP -t '~'"/test/sync.sh local-sync $1"
}

results ()
{
  rsync -avz                      \
    -e "ssh -i $LOCAL_IDENTITY_FILE -o ProxyCommand=\"ssh -W %h:%p $USERNAME@$BASTION_IP -i $LOCAL_IDENTITY_FILE\" -o \"StrictHostKeyChecking no\" -o \"UserKnownHostsFile /dev/null\"" \
    $USERNAME@$ROUTER_MANAGEMENT_IP:~/currentrun/    \
    $SCRIPTDIR/results/
}

_local_rsync ()
{
  if [[ "$1" != "" ]]; then
    rsync -avz                      \
      -e "ssh -i $IDENTITY_FILE"    \
      --exclude=currentrun          \
      --exclude=results             \
      --exclude=.*                  \
      ~/test/ $USERNAME@$1:~/test
  fi
}

local_sync ()
{
  mv ~/test/conf/$1 ~/test/myconf.sh
  source ~/test/myconf.sh
  mv ~/test/${LOCAL_IDENTITY_FILE##*/} $IDENTITY_FILE
  _local_rsync $VM1_MANAGEMENT_IP
  _local_rsync $ROUTER_MANAGEMENT_IP
  _local_rsync $ROUTER2_MANAGEMENT_IP
}

print_usage ()
{
  echo "Usage:"
  echo "sync.sh conf_file sync              - sync to vms"
  echo "sync.sh conf_file results           - get results from vm"
  echo "sync.sh conf_file [vm1|vm2|sw1|sw2] - get a shell in an instance"
}

ovh_netconf ()
{
  ssh $USERNAME@$BASTION_IP -i $LOCAL_IDENTITY_FILE -t "sudo ip link set ens4 up ; sudo ip addr add $BASTION_MANAGEMENT_IP/24 dev ens4 || true  > /dev/null"
  ssh $USERNAME@$VM1_EXTERNAL_IP -i $LOCAL_IDENTITY_FILE -t "sudo ip link set ens4 up ; sudo ip link set ens7 up ; sudo ip addr add $VM1_MANAGEMENT_IP/24 dev ens7 || true > /dev/null"
  ssh $USERNAME@$VM2_EXTERNAL_IP -i $LOCAL_IDENTITY_FILE -t "sudo ip link set ens4 up ; sudo ip link set ens7 up ; sudo ip addr add $VM2_MANAGEMENT_IP/24 dev ens7 || true > /dev/null"
  ssh $USERNAME@$SW1_EXTERNAL_IP -i $LOCAL_IDENTITY_FILE -t "sudo ip link set ens4 up ; sudo ip link set ens7 up ; sudo ip addr add $ROUTER_MANAGEMENT_IP/24 dev ens7 || true > /dev/null"
  ssh $USERNAME@$SW2_EXTERNAL_IP -i $LOCAL_IDENTITY_FILE -t "sudo ip link set ens4 up ; sudo ip link set ens7 up ; sudo ip addr add $ROUTER2_MANAGEMENT_IP/24 dev ens7 || true > /dev/null"
}

sync_cli ()
{
  # TESTING
  if [[ "$1" = "" ]]; then
    print_usage
  elif [[ "$1" = "local-sync" ]]; then
    local_sync ${@:2}
    exit 0
  else
    source $1
    FNAME=$1
  fi
  shift
  if [[ "$1" = "sync" ]]; then
    sync ${FNAME##*/}
  elif [[ "$1" = "ovhnetconf" ]]; then
    ovh_netconf
  elif [[ "$1" = "results" ]]; then
    results
  elif [[ "$1" = "vm1" ]]; then
    _ssh_cmd $VM1_MANAGEMENT_IP
  elif [[ "$1" = "vm2" ]]; then
    _ssh_cmd $VM2_MANAGEMENT_IP
  elif [[ "$1" = "sw1" ]]; then
    _ssh_cmd $ROUTER_MANAGEMENT_IP
  elif [[ "$1" = "sw2" ]]; then
    _ssh_cmd $ROUTER2_MANAGEMENT_IP
  else
    print_usage
  fi
}

sync_cli $@
