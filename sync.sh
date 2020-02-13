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
    --exclude=.*                  \
    --include=$1                  \
    --exclude=*-conf.sh           \
    $SCRIPTDIR/                   \
    $LOCAL_IDENTITY_FILE          \
    $USERNAME@$VM2_MANAGEMENT_IP:~/test/
  _ssh_cmd $VM2_MANAGEMENT_IP -t '~'"/test/sync.sh local-sync $1"
}

_local_rsync ()
{
  rsync -avz                      \
    -e "ssh -i $IDENTITY_FILE"    \
    --exclude=currentrun          \
    --exclude=results             \
    --exclude=.*                  \
    ~/test/ $USERNAME@$1:~/test
}

local_sync ()
{
  mv ~/test/$1 ~/test/myconf.sh
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
  echo "sync.sh conf_file [vm1|vm2|sw1|sw2] - get a shell in an instance"
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