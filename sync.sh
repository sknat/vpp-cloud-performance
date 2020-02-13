#!/bin/bash

source $( dirname "${BASH_SOURCE[0]}" )/shared.sh

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
  ssh \
    -i $LOCAL_IDENTITY_FILE \
    -o ProxyCommand="ssh -W %h:%p $USERNAME@$BASTION_IP -i $LOCAL_IDENTITY_FILE" \
    -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" \
    $USERNAME@$VM2_MANAGEMENT_IP \
    -t '~'"/test/sync.sh local-sync $1"
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

sync_cli ()
{
  # TESTING
  if [[ "$1" = "" ]]; then
    echo "Please provide a config file"
  elif [[ "$1" = "local-sync" ]]; then
    local_sync ${@:2}
  else
    source $1
    sync ${1##*/}
  fi
}

sync_cli $@
