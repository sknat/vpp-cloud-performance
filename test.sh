#!/bin/bash

set -e

TIME=${TIME-20} # test duration
NRUN=${NRUN-3} # Number of test runs
BIDI=${BIDI-""} # bidirectional iperf3 (one out of two is reversed)
CONF=${CONF-"two"} # one|two|zero (number of hops for azure vm2 client)
NFORKS=${NFORKS-1} # number of parallel iperfs
FLOWS=${FLOWS-1} # flows per iperf3 (-P#)

IDENTITY_FILE=~/nskrzypc-key.pem
VPP_RUN_DIR=/run/vpp

# aws

VM1_MANAGEMENT_IP=20.0.1.1
ROUTER_MANAGEMENT_IP=20.0.1.2
ROUTER2_MANAGEMENT_IP=20.0.1.3
VM2_MANAGEMENT_IP=20.0.1.4

VM1_IP=20.0.2.1
VM1_LAST_IP=20.0.2.100
VM2_IP=20.0.7.1
VM2_LAST_IP=20.0.7.100

# azure

# VM1_MANAGEMENT_IP=20.0.1.4
# ROUTER_MANAGEMENT_IP=20.0.1.6
# ROUTER2_MANAGEMENT_IP=20.0.1.7
# VM2_MANAGEMENT_IP=20.0.1.5

# VM1_IP=20.0.2.64
# VM1_LAST_IP=20.0.2.127

# VM2_IP=20.0.7.64
# VM2_LAST_IP=20.0.7.127

# VM2_IP2=20.0.4.192
# VM2_LAST_IP2=20.0.4.255

# VM2_IP3=20.0.2.192
# VM2_LAST_IP3=20.0.2.255

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SCRIPTDIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

function join_by { local d=$1; shift; echo -n "$1"; shift; printf "%s" "${@/#/$d}"; }

function ask_continue () {
  while true; do
      read -p "$1 : " yn
      case $yn in
          [Yy]* ) break;;
          [Nn]* ) exit;;
          * ) echo "Please answer yes or no.";;
      esac
  done
}

run_ () {
  ssh ubuntu@$1 -i $IDENTITY_FILE -t ${@:2}
}

ip_it ()
{
  ret=""
  first="${1##*.*.*.}"
  for ((i = $first; i <= ${2##*.*.*.}; i++)); do
    ret="$ret ${1%%.$first}.$i"
  done
  echo $ret
}

VM1_IP_IT=($(ip_it $VM1_IP $VM1_LAST_IP))

bindip_for_client_vm ()
{
  # VM2_IP2_IT=($(ip_it $VM2_IP2 $VM2_LAST_IP2))
  # VM2_IP3_IT=($(ip_it $VM2_IP3 $VM2_LAST_IP3))
  VM2_IP_IT=($(ip_it $VM2_IP $VM2_LAST_IP))
  fork=$1
  if [[ "$CONF" = "one" ]] ; then
    # one hop route to VM1
    BINDIP=${VM2_IP2_IT[$fork]}
  elif [[ "$CONF" = "zero" ]]; then
    # zero hop route to VM1
    BINDIP=${VM2_IP3_IT[$fork]}
  else
    BINDIP=${VM2_IP_IT[$fork]}
  fi
  echo "$BINDIP"
}

sync ()
{
  if [[ "$1" = "" ]]; then
    echo "Provide az|aw"
    exit 1
  fi

  rsync -avz              \
    --exclude=currentrun  \
    --exclude=results     \
    --exclude=.*          \
    $SCRIPTDIR/ $1.vm2:~/test/
  ssh $1.vm2 -t '~/test/test.sh local-sync'
}

_local_rsync ()
{
  rsync -avz                      \
    -e "ssh -i $IDENTITY_FILE"    \
    --exclude=currentrun          \
    --exclude=results             \
    --exclude=.*                  \
    ~/test/ ubuntu@$1:~/test
}

local_sync ()
{
  _local_rsync $VM1_MANAGEMENT_IP
  _local_rsync $ROUTER_MANAGEMENT_IP
  _local_rsync $ROUTER2_MANAGEMENT_IP
}

get_dir_name ()
{
  NAME=$1
  NFORKS=$2
  echo "currentrun/${NAME}.${NFORKS}t"
}

get_test_name ()
{
  NAME=$1
  RUN=$2
  NFORKS=$3
  FORK=$4
  DIR=$(get_dir_name $NAME $NFORKS)
  mkdir -p ~/$DIR
  echo "$DIR/run$RUN.fork${FORK}"
}

clear_run ()
{
  if [[ "$(pgrep vpp)" = "" ]]; then
    exit 0
  fi
  sudo vppctl clear run
  sudo vppctl clear err
  sudo vppctl clear log
}

show_run ()
{
  NAME=$1
  RUN=$2
  NFORKS=$3
  FORK=$4
  if [[ "$(pgrep vpp)" = "" ]]; then
    exit 0
  fi
  FNAME=$(get_test_name $NAME $RUN $NFORKS $FORK)
  sudo vppctl show hardware-interfaces > $FNAME.hwi
  sudo vppctl show run > $FNAME.run
  sudo vppctl show err > $FNAME.err
  sudo vppctl show log > $FNAME.log
  cp $VPP_RUN_DIR/vpp.conf $FNAME.vpp.conf
  cp $VPP_RUN_DIR/startup.conf $FNAME.vpp.startup.conf
}

start_parallel_servers ()
{
  NAME=$1
  RUN=$2
  NFORKS=$3
  sudo pkill iperf3 > /dev/null 2>&1 || true
  for ((fork = 0; fork < $NFORKS; fork++)); do
    FNAME=$(get_test_name $NAME $RUN $NFORKS $fork)
    iperf3 -s -B ${VM1_IP_IT[$fork]} -D -I ~/iperf3.fork$fork.pid --logfile ~/$FNAME.server > /dev/null 2>&1
  done
}

stop_parallel_servers ()
{
  sudo pkill iperf3 > /dev/null 2>&1 || true
}

clear_test ()
{
  run_ $ROUTER_MANAGEMENT_IP "rm -rf ~/currentrun/$1"
  run_ $ROUTER2_MANAGEMENT_IP "rm -rf ~/currentrun/$1"
  run_ $VM1_MANAGEMENT_IP "rm -rf ~/currentrun/$1"
  rm -rf ~/currentrun/$1
  echo "Removed test ~/currentrun/$1"
}

trap_exit ()
{
  run_ $VM1_MANAGEMENT_IP "~/test/test.sh stop-server" > /dev/null 2>&1
  rm ~/iperf3.*pid
  echo "Test aborted"
}

start_parallel_clients ()
{
  NAME=$1
  DIR=$(get_dir_name $NAME $NFORKS)
  if [[ -d ~/$DIR ]]; then
    ask_continue "Test case exists, erase and redo ?"
    clear_test $NAME
  fi

  trap trap_exit 2

  echo "-- Starting test $NAME --"
  echo "${NFORKS} x iperf3"
  echo "${FLOWS} flows"
  echo "${TIME}s duration"
  echo "${NRUN} runs"
  if [[ "$BIDI" != "" ]]; then echo "bidirectional" ; fi
  echo "-------------------------"

  RESULTS=()
  for RUN in $(seq $NRUN) ; do
  run_ $ROUTER_MANAGEMENT_IP "~/test/test.sh clear-run" > /dev/null 2>&1
  run_ $ROUTER2_MANAGEMENT_IP "~/test/test.sh clear-run" > /dev/null 2>&1
  run_ $VM1_MANAGEMENT_IP "nohup ~/test/test.sh start-server $NAME $RUN $NFORKS > /dev/null 2>&1" > /dev/null 2>&1
  for ((fork = 0; fork < $NFORKS; fork++)); do
    FNAME=$(get_test_name $NAME $RUN $NFORKS $fork)
    if [[ "$BIDI" != "" ]] && [[ $((fork%2)) = 1 ]]; then
          REVERSED="-R"
    else
          REVERSED=""
    fi
    BINDIP=$(bindip_for_client_vm $fork)
    iperf3 $REVERSED -c ${VM1_IP_IT[$fork]} -B ${BINDIP} -i 1 -t $TIME -P ${FLOWS} ${@:3} --logfile ~/$FNAME.client > /dev/null 2>&1 &
    echo "$!" > ~/iperf3.fork$fork.pid
  done
  for ((fork = 0; fork < $NFORKS; fork++)); do
    wait $(cat ~/iperf3.fork$fork.pid)
    rm ~/iperf3.fork$fork.pid
  done
  BPS=0
  for ((fork = 0; fork < $NFORKS; fork++)); do
    FNAME=$(get_test_name $NAME $RUN $NFORKS $fork)
    if [[ "$BIDI" != "" ]] && [[ $((fork%2)) = 1 ]]; then
      REVERSED="-R"
    else
      REVERSED=""
    fi
    BINDIP=$(bindip_for_client_vm $fork)
    echo "iperf3 $REVERSED -c ${VM1_IP_IT[$fork]} -B ${BINDIP} -i 1 -t $TIME -P ${FLOWS} ${@:3}" > ~/$FNAME.cli
    run_ $VM1_MANAGEMENT_IP "~/test/test.sh stop-server" > /dev/null 2>&1
    BPSG_=$(tail -n 3 ~/$FNAME.client | head -1 | egrep -o "[0-9\.]+ Gbits/s" | egrep -o "[0-9\.]+" || echo "0")
    BPSM_=$(tail -n 3 ~/$FNAME.client | head -1 | egrep -o "[0-9\.]+ Mbits/s" | egrep -o "[0-9\.]+" || echo "0")
    BPSK_=$(tail -n 3 ~/$FNAME.client | head -1 | egrep -o "[0-9\.]+ Kbits/s" | egrep -o "[0-9\.]+" || echo "0")
    BPS=$(echo $BPS $BPSG_ $BPSM_ $BPSK_ | awk '{print $1 + $2 + ($3 / 1000) + ($4 / 1000000)}')
  done
  run_ $ROUTER_MANAGEMENT_IP "~/test/test.sh show-run $NAME $RUN $NFORKS .router1" > /dev/null 2>&1
  run_ $ROUTER2_MANAGEMENT_IP "~/test/test.sh show-run $NAME $RUN $NFORKS .router2" > /dev/null 2>&1
  echo "${NAME} run #${RUN} DONE at ${BPS} Gbits/s"
  RESULTS+=($BPS)
  done
  echo -e "Results :: "$(join_by '\t' ${RESULTS[@]} | sed "s/\./,/g")
  rsync -avz -e "ssh -i $IDENTITY_FILE" ubuntu@$ROUTER_MANAGEMENT_IP:~/currentrun/ ./currentrun > /dev/null 2>&1
  rsync -avz -e "ssh -i $IDENTITY_FILE" ubuntu@$ROUTER2_MANAGEMENT_IP:~/currentrun/ ./currentrun > /dev/null 2>&1
  rsync -avz -e "ssh -i $IDENTITY_FILE" ubuntu@$VM1_MANAGEMENT_IP:~/currentrun/ ./currentrun > /dev/null 2>&1
}
# BPS=$(cat ~/$1.P$NTHREAD.run$RUN.client.json | jq '.end.sum_received.bits_per_second / 1000000000')

test_cli ()
{
  # TESTING
  if [[ "$1" = "sync" ]]; then
    sync ${@:2}
  elif [[ "$1" = "local-sync" ]]; then # internal
    local_sync ${@:2}
  elif [[ "$1" = "clear" ]]; then
    clear_test ${@:2}
  elif [[ "$1" = "ptest" ]]; then
    start_parallel_clients ${@:2}
  elif [[ "$1" = "start-server" ]]; then # internal
    start_parallel_servers ${@:2}
  elif [[ "$1" = "stop-server" ]]; then # internal
    stop_parallel_servers ${@:2}
  elif [[ "$1" = "clear-run" ]]; then # internal
    clear_run ${@:2}
  elif [[ "$1" = "show-run" ]]; then # internal
    show_run ${@:2}
  else
    echo "Usage:"
    echo "test.sh ptest [NAME] [N] [OPTIONS]     - run N iperf3, store results with name NAME and options OPTIONS"
    echo "test.sh clear [NAME]                   - Delete test results NAME"
  fi
}

test_cli $@

