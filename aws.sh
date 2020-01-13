#!/bin/bash

set -e

# ------------------------------

IDENTITY_FILE=~/nskrzypc-key.pem

MTU=${MTU-9000}
WRK=${WRK-4} # N workers
TIME=${TIME-20} # test duration

VM1_IP=10.0.0.155
VM1_LAST_IP=10.0.0.158
VM1_IF=ens5

ROUTER_MANAGEMENT_IP=10.0.0.49
ROUTER2_MANAGEMENT_IP=10.0.0.123

# ROUTER interface towards VM1
ROUTER_VM1_IF=ens6
ROUTER_VM1_IF_PCI=0000:00:06.0
ROUTER_VM1_IP=10.0.0.11
ROUTER_VM1_NAME=VirtualFunctionEthernet0/6/0
ROUTER_VM2_MAC=02:32:86:8a:04:2e

# ROUTER interface towards VM2
ROUTER_VM2_IF=ens7
ROUTER_VM2_IF_PCI=0000:00:07.0
ROUTER_VM2_IP=10.0.0.12
ROUTER_VM2_LAST_IP=10.0.0.15
ROUTER_VM2_NAME=VirtualFunctionEthernet0/7/0

# ROUTER interface towards VM1
ROUTER2_VM1_IF=ens6
ROUTER2_VM1_IF_PCI=0000:00:06.0
ROUTER2_VM1_IP=10.0.0.51
ROUTER2_VM1_LAST_IP=10.0.0.54
ROUTER2_VM1_NAME=VirtualFunctionEthernet0/6/0
ROUTER2_VM1_MAC=02:6a:37:57:dd:b4

# ROUTER interface towards VM2
ROUTER2_VM2_IF=ens7
ROUTER2_VM2_IF_PCI=0000:00:07.0
ROUTER2_VM2_IP=10.0.0.72
ROUTER2_VM2_NAME=VirtualFunctionEthernet0/7/0

VM2_IP=10.0.0.130
VM2_LAST_IP=10.0.0.133
VM2_IF=ens5

VPP_DIR=/home/ubuntu/vpp
VPP_RUN_DIR=/run/vpp
DPDK_DEVBIND=$VPP_DIR/build-root/install-vpp-native/external/sbin/dpdk-devbind
TESTPMD=$VPP_DIR/build-root/install-vpp-native/external/bin/testpmd
VPPBIN=$VPP_DIR/build-root/install-vpp-native/vpp/bin/vpp
VPPCTLBIN=$VPP_DIR/build-root/install-vpp-native/vpp/bin/vppctl
IGB_UIO_KO=$VPP_DIR/build-root/build-vpp-native/external/dpdk-19.08/x86_64-native-linuxapp-gcc/kmod/igb_uio.ko

# ------------------------------

# iterator between two ips, assumes only last term changes
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
VM2_IP_IT=($(ip_it $VM2_IP $VM2_LAST_IP))
ROUTER_VM2_IP_IT=($(ip_it $ROUTER_VM2_IP $ROUTER_VM2_LAST_IP))
ROUTER2_VM1_IP_IT=($(ip_it $ROUTER2_VM1_IP $ROUTER2_VM1_LAST_IP))

echo "MTU=$MTU Nwrk=$WRK"

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SCRIPTDIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
if [[ -f .me ]]; then
  ME=$(cat ~/.me)
else
  ME=""
fi

run_ () {
  if [[ "$1" = "$ME" ]]; then
    ${@:2}
  else
    ssh ubuntu@$1 -i $IDENTITY_FILE -t ${@:2}
  fi
}
srun_ () {
  run_ $1 "sudo ${@:2}";
}

get_mac () { run_ $1 "sed -n 1p /sys/class/net/$2/address" ; }

configure_test_pmd ()
{
  srun_ switch "modprobe vfio-pci"
  echo 1 | srun_ switch "tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode"
  srun_ switch "$DPDK_DEVBIND --force -b vfio-pci $ROUTER_VM1_IF_PCI"
  srun_ switch "$DPDK_DEVBIND --force -b vfio-pci $ROUTER_VM2_IF_PCI"
  srun_ switch "sysctl -w vm.nr_hugepages=1024"

  srun_ vm1 "ip link set $VM1_IF mtu $MTU"
  srun_ vm2 "ip link set $VM2_IF mtu $MTU"

  VM1_MAC=$(get_mac vm1 $VM1_IF)
  VM2_MAC=$(get_mac vm2 $VM2_IF)

  srun_ switch "$TESTPMD
  -w $ROUTER_VM1_IF_PCI
  -w $ROUTER_VM2_IF_PCI
  -l 0,1,2,3,4,5
  -- -a
  --forward-mode=mac
  --burst=32
  --eth-peer=1,${VM1_MAC//[$'\r']}
  --eth-peer=0,${VM2_MAC//[$'\r']}
  --rss
  --rxq=4
  --txq=4
  --nb-cores=4"
}

configure_raw ()
{
  srun_ vm1 "ip link set $VM1_IF mtu $MTU"
  srun_ vm2 "ip link set $VM2_IF mtu $MTU"
  srun_ $ME "ip link set $ROUTER_VM1_IF mtu $MTU"
  srun_ $ME "ip link set $ROUTER_VM2_IF mtu $MTU"
}

configure_linux_router ()
{
  srun_ switch "ip link set $ROUTER_VM1_IF up"
  srun_ switch "ip link set $ROUTER_VM2_IF up"
  srun_ switch "ip addr add $ROUTER_VM1_IP dev $ROUTER_VM1_IF" || true
  srun_ switch "ip addr add $ROUTER_VM2_IP dev $ROUTER_VM2_IF"  || true
  srun_ switch "ip route add $VM1_IP via $ROUTER_VM1_IP"  || true
  srun_ switch "ip route add $VM2_IP via $ROUTER_VM2_IP"  || true
  srun_ switch "sysctl net.ipv4.ip_forward=1"

  ROUTER_VM1_MAC=$(get_mac switch $ROUTER_VM1_IF)
  srun_ vm1 "arp -s $VM2_IP ${ROUTER_VM1_MAC//[$'\r']}"
  srun_ vm2 "arp -s $VM1_IP ${ROUTER_VM2_MAC//[$'\r']}"

  srun_ vm1 "ip link set $VM1_IF mtu $MTU"
  srun_ vm2 "ip link set $VM2_IF mtu $MTU"
  srun_ switch "ip link set $ROUTER_VM1_IF mtu $MTU"
  srun_ switch "ip link set $ROUTER_VM2_IF mtu $MTU"
}

install_deps ()
{
  if [[ "$ME" = "vm1" ]] || [[ "$ME" = "vm2" ]]; then
    srun_ $ME "apt update && apt install -y iperf iperf3 traceroute"
  else
    run_ $ME "git clone https://gerrit.fd.io/r/vpp" || true
    run_ $ME "cd vpp && make install-dep"
    run_ $ME "git apply ~/vpp-dpdk.patch" || true
    run_ $ME "cd vpp && make build-release"
  fi
}

sync_dns ()
{
  echo "Syncing hostnames"
  grep -q "^$VM1_IP" /etc/hosts && sudo sed -i "s/^$VM1_IP.*/$VM1_IP vm1/" /etc/hosts || echo "$VM1_IP vm1" | sudo tee -a /etc/hosts
  grep -q "^$VM2_IP" /etc/hosts && sudo sed -i "s/^$VM2_IP.*/$VM2_IP vm2/" /etc/hosts || echo "$VM2_IP vm2" | sudo tee -a /etc/hosts
  grep -q "^$ROUTER2_MANAGEMENT_IP" /etc/hosts && sudo sed -i "s/^$ROUTER2_MANAGEMENT_IP.*/$ROUTER2_MANAGEMENT_IP switch2/" /etc/hosts || echo "$ROUTER2_MANAGEMENT_IP switch2" | sudo tee -a /etc/hosts
  grep -q "^$ROUTER_MANAGEMENT_IP" /etc/hosts && sudo sed -i "s/^$ROUTER_MANAGEMENT_IP.*/$ROUTER_MANAGEMENT_IP switch/" /etc/hosts || echo "$ROUTER_MANAGEMENT_IP switch" | sudo tee -a /etc/hosts
}

# BPS=$(cat ~/$1.P$NTHREAD.run$RUN.client.json | jq '.end.sum_received.bits_per_second / 1000000000')
test_client ()
{
  if [[ "$1" = "" ]]; then
    echo "Please provide a name"
    exit
  fi
  echo "starting tests, $TIME sec per test"
  for RUN in 1 2 3 ; do
  for NTHREAD in 1 4 8 16 ; do
    FNAME="$1.MTU$MTU.P$NTHREAD.run$RUN"
    run_ vm1 "nohup iperf3 -s -D -I ~/iperf3.pid --logfile ~/$FNAME.server > /dev/null 2>&1" > /dev/null 2>&1
    iperf3 -c vm1 -i 1 -t $TIME -P$NTHREAD ${@:2} > ~/$FNAME.client
    run_ vm1 'kill `cat ~/iperf3.pid`' > /dev/null 2>&1
    sed -i -e "1i COMMAND::iperf3 -c vm1 -i 1 -t $TIME -P$NTHREAD ${@:2}" ~/$FNAME.client
    BPS=$(tail -n 3 ~/$FNAME.client | head -1 | egrep -o "[0-9\.]+ Gbits/s")
    echo "$FNAME : $BPS"
  done
  done
}

test_parallel_clients ()
{
  if [[ "$1" = "" ]] || [[ "$2" = "" ]]; then
    echo "Please provide a name & a number of iperfs"
    exit
  fi
  NFORKS=$2
  srun_ vm1 "pkill iperf3" > /dev/null 2>&1 || true
  echo "starting $NFORKS parallel tests, $TIME sec per test"
  NTHREAD=1
  for RUN in 1 2 3 ; do
  for ((fork = 0; fork < $NFORKS; fork++)); do
    FNAME="$1.MTU$MTU.P$NTHREAD.run$RUN.fork$fork"
    # echo "start server for $FNAME"
    run_ vm1 "nohup iperf3 -s -B ${VM1_IP_IT[$fork]} -D -I ~/iperf3.fork$fork.pid --logfile ~/$FNAME.server > /dev/null 2>&1" > /dev/null 2>&1
  done
  for ((fork = 0; fork < $NFORKS; fork++)); do
    FNAME="$1.MTU$MTU.P$NTHREAD.run$RUN.fork$fork"
    # echo "start client for $FNAME"
    iperf3 -c ${VM1_IP_IT[$fork]} -B ${VM2_IP_IT[$fork]} -i 1 -t $TIME -P$NTHREAD ${@:3} --logfile ~/$FNAME.client > /dev/null 2>&1 &
    # echo "Forked client pid $!"
    echo "$!" > ~/iperf3.fork$fork.pid
  done
  BPS=0
  for ((fork = 0; fork < $NFORKS; fork++)); do
    # echo "joining ~/iperf3.fork$fork.pid"
    wait $(cat ~/iperf3.fork$fork.pid)
    rm ~/iperf3.fork$fork.pid
    sed -i -e "1i COMMAND::iperf3 -c ${VM1_IP_IT[$fork]} -B ${VM2_IP_IT[$fork]} -i 1 -t $TIME -P$NTHREAD ${@:3}" ~/$FNAME.client
    run_ vm1 "kill \$(cat ~/iperf3.fork$fork.pid)" > /dev/null 2>&1
    BPS_=$(tail -n 3 ~/$FNAME.client | head -1 | egrep -o "[0-9\.]+ Gbits/s" | egrep -o "[0-9\.]+" )
    BPS=$(echo $BPS $BPS_ | awk '{print $1 + $2}')
  done
  echo "$1.MTU$MTU.P$NTHREAD.run$RUN : $BPS Gbits/s"
  done
}

create_vpp_startup_conf ()
{
  if [[ "$WRK" = "1" ]]; then
    CORELIST_WORKERS="1"
  else
    CORELIST_WORKERS="1-$WRK"
  fi
  srun_ $ME "mkdir -p $VPP_RUN_DIR"
  echo "
unix {
  log $VPP_RUN_DIR/vpp.log
  cli-listen $VPP_RUN_DIR/cli.sock
  exec $VPP_RUN_DIR/startup.conf
}
cpu {
  main-core 0
  corelist-workers $CORELIST_WORKERS
}
dpdk {
  uio-driver $DPDK_DRIVER
  dev $ROUTER_VM1_IF_PCI { num-rx-queues $WRK }
  dev $ROUTER_VM2_IF_PCI { num-rx-queues $WRK }
}
" | srun_ $ME tee $VPP_RUN_DIR/vpp.conf > /dev/null
}

configure_vpp_nic_drivers ()
{
  if [[ "$1" = "uio" ]]; then
    srun_ $ME "modprobe uio"
    srun_ $ME "insmod $IGB_UIO_KO wc_activate=1" || true
    DPDK_DRIVER="igb_uio"
  else
    srun_ $ME "modprobe vfio-pci"
    DPDK_DRIVER="vfio-pci"
  fi
  echo 1 | srun_ $ME "tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode"
}

configure_vpp ()
{
  configure_vpp_nic_drivers $1
  create_vpp_startup_conf

  # ----------------- Startup CLIs -----------------
  VM1_MAC=$(get_mac vm1 $VM1_IF)
  VM2_MAC=$(get_mac vm2 $VM2_IF)
  echo "
set int state $ROUTER_VM1_NAME up
set int state $ROUTER_VM2_NAME up
set int ip address $ROUTER_VM1_NAME 127.0.0.1/32
set int ip address $ROUTER_VM2_NAME 127.0.0.2/32
ip route add $VM1_IP/32 via $ROUTER_VM1_NAME
ip route add $VM2_IP/32 via $ROUTER_VM2_NAME
set ip neighbor $ROUTER_VM1_NAME $VM1_IP ${VM1_MAC//[$'\r']}
set ip neighbor $ROUTER_VM2_NAME $VM2_IP ${VM2_MAC//[$'\r']}
set int mtu $MTU $ROUTER_VM1_NAME
set int mtu $MTU $ROUTER_VM2_NAME
" | srun_ switch tee $VPP_RUN_DIR/startup.conf > /dev/null

  # ----------------- ARP entries -----------------
  ROUTER_VM1_MAC=$(get_mac switch $ROUTER_VM1_IF)
  srun_ vm1 "arp -s $VM2_IP ${ROUTER_VM1_MAC//[$'\r']}"
  srun_ vm2 "arp -s $VM1_IP ${ROUTER_VM2_MAC//[$'\r']}"
  srun_ vm1 "ip link set $VM1_IF mtu $MTU"
  srun_ vm2 "ip link set $VM2_IF mtu $MTU"

  # ----------------- RUN -----------------
  srun_ switch "ln -s $VPPCTLBIN /usr/local/bin/vppctl" || true
  srun_ switch "$VPPBIN -c $VPP_RUN_DIR/vpp.conf"
}

unconfigure_all ()
{
  srun_ pkill vpp || true
  srun_ switch "$DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI"
  srun_ switch "$DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI"
  srun_ switch "ip link set $ROUTER_VM1_IF down"
  srun_ switch "ip link set $ROUTER_VM2_IF down"
  srun_ vm2 "arp -d $VM1_IP" || true
  srun_ vm1 "arp -d $VM2_IP" || true
}

sync ()
{
  rsync -avz --delete     \
    --exclude=results     \
    --exclude=.gitignore  \
    $SCRIPTDIR/* $1:~/
  ssh $1 -t "echo $1 > .me ; bash aws.sh dns"
}

configure_vpp_ipsec_1 ()
{
  srun_ switch "pkill vpp" || true
  srun_ switch "$DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI"
  srun_ switch "$DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI"
  srun_ switch "ip link set $ROUTER_VM1_IF down"
  srun_ switch "ip link set $ROUTER_VM2_IF down"
  srun_ vm1 "arp -d $VM2_IP" || true

  configure_vpp_nic_drivers $1
  create_vpp_startup_conf

  # ----------------- Startup CLIs -----------------
  VM1_MAC=$(get_mac vm1 $VM1_IF)
  echo "
set int state $ROUTER_VM1_NAME up
set int state $ROUTER_VM2_NAME up
set int ip address $ROUTER_VM1_NAME $ROUTER_VM1_IP/32

ipsec sa add 20 spi 200 crypto-key 6541686776336961656264656f6f6579 crypto-alg aes-gcm-128
ipsec sa add 30 spi 300 crypto-key 6541686776336961656264656f6f6579 crypto-alg aes-gcm-128

ip route add $ROUTER2_VM1_IP/32 via $ROUTER_VM2_NAME
" | srun_ switch tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    echo "
set int ip address $ROUTER_VM2_NAME ${ROUTER_VM2_IP_IT[$i]}/32
create ipip tunnel src ${ROUTER_VM2_IP_IT[$i]} dst ${ROUTER2_VM1_IP_IT[$i]}
ipsec tunnel protect ipip$i sa-in 20 sa-out 30

set int state ipip$i up
set int ip addr ipip$i 127.0.0.$((i+1))/32
set ip neighbor $ROUTER_VM2_NAME ${ROUTER2_VM1_IP_IT[$i]} ${ROUTER2_VM1_MAC//[$'\r']}
set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}

ip route add ${VM1_IP_IT[$i]}/32 via $ROUTER_VM1_NAME
ip route add ${VM2_IP_IT[$i]}/32 via ipip$i
ip route add ${ROUTER2_VM1_IP_IT[$i]}/32 via $ROUTER_VM2_NAME
" | srun_ switch tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  done

  # ----------------- ARP entries -----------------
  ROUTER_VM1_MAC=$(get_mac switch $ROUTER_VM1_IF)
  cmd=""
  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    cmd="${cmd}sudo arp -s ${VM2_IP_IT[$i]} ${ROUTER_VM1_MAC//[$'\r']} ;"
    # cmd="${cmd}sudo ip addr add ${VM1_IP_IT[$i]}/32 dev ens5 ;"
  done
  run_ vm1 "$cmd"
  srun_ vm1 "ip link set $VM1_IF mtu $MTU"

  # ----------------- RUN -----------------
  srun_ switch "ln -s $VPPCTLBIN /usr/local/bin/vppctl" || true
  srun_ switch "$VPPBIN -c $VPP_RUN_DIR/vpp.conf"
}

configure_vpp_ipsec_2 ()
{
  srun_ switch2 "pkill vpp" || true
  srun_ switch2 "$DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI"
  srun_ switch2 "$DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI"
  srun_ switch2 "ip link set $ROUTER_VM1_IF down"
  srun_ switch2 "ip link set $ROUTER_VM2_IF down"
  srun_ vm2 "arp -d $VM1_IP" || true

  configure_vpp_nic_drivers $1
  create_vpp_startup_conf

  # ----------------- Startup CLIs -----------------
  VM2_MAC=$(get_mac vm2 $VM2_IF)
  echo "
set int state $ROUTER2_VM1_NAME up
set int state $ROUTER2_VM2_NAME up
set int ip address $ROUTER2_VM2_NAME $ROUTER2_VM2_IP/32

ipsec sa add 20 spi 200 crypto-key 6541686776336961656264656f6f6579 crypto-alg aes-gcm-128
ipsec sa add 30 spi 300 crypto-key 6541686776336961656264656f6f6579 crypto-alg aes-gcm-128

" | srun_ switch2 tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    echo "
set int ip address $ROUTER2_VM1_NAME ${ROUTER2_VM1_IP_IT[$i]}/32
create ipip tunnel src ${ROUTER2_VM1_IP_IT[$i]} dst ${ROUTER_VM2_IP_IT[$i]}
ipsec tunnel protect ipip$i sa-in 30 sa-out 20

set int state ipip$i up
set int ip addr ipip$i 127.0.0.$((i+1))/32
set ip neighbor $ROUTER2_VM1_NAME ${ROUTER_VM2_IP_IT[$i]} ${ROUTER_VM2_MAC//[$'\r']}
set ip neighbor $ROUTER2_VM2_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}

ip route add ${VM2_IP_IT[$i]}/32 via $ROUTER2_VM2_NAME
ip route add ${VM1_IP_IT[$i]}/32 via ipip$i
ip route add ${ROUTER_VM2_IP_IT[$i]}/32 via $ROUTER_VM2_NAME
" | srun_ switch2 tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  done

  # ----------------- ARP entries -----------------
  ROUTER2_VM2_MAC=$(get_mac switch2 $ROUTER_VM2_IF)
  cmd=""
  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    cmd="${cmd}sudo arp -s ${VM1_IP_IT[$i]} ${ROUTER2_VM2_MAC//[$'\r']} ;"
    # cmd="${cmd}sudo ip addr add ${VM2_IP_IT[$i]}/32 dev ens5 ;"
  done
  run_ vm2 "$cmd"
  srun_ vm2 "ip link set $VM2_IF mtu $MTU"

  # ----------------- RUN -----------------
  srun_ switch2 "ln -s $VPPCTLBIN /usr/local/bin/vppctl" || true
  srun_ switch2 "$VPPBIN -c $VPP_RUN_DIR/vpp.conf"
}

aws_test_cli ()
{
  if [[ "$1" = "dns" ]]; then
    sync_dns
  elif [[ "$1" = "sync" ]]; then
    sync switch
    sync switch2
    sync vm1
    sync vm2
  elif [[ "$1" = "install" ]]; then
    install_deps
  elif [[ "$1" = "raw" ]]; then
    unconfigure_all
    configure_raw
  elif [[ "$1" = "pmd" ]]; then
    unconfigure_all
    configure_test_pmd
  elif [[ "$1" = "linux" ]]; then
    unconfigure_all
    configure_linux_router
  elif [[ "$1" = "vpp" ]]; then
    unconfigure_all
    configure_vpp ${@:2}
  elif [[ "$1" = "ipsec1" ]]; then
    configure_vpp_ipsec_1 ${@:2}
  elif [[ "$1" = "ipsec2" ]]; then
    configure_vpp_ipsec_2 ${@:2}
  elif [[ "$1" = "test" ]]; then
    test_client ${@:2}
  elif [[ "$1" = "ptest" ]]; then
    test_parallel_clients ${@:2}
  else
    echo "Usage:"
    echo "aws.sh sync [HOST]  - sync this script to the host HOST"
    echo "aws.sh dns          - Add /etc/hosts entries with names vm1/vm2/switch"
    echo "aws.sh install      - install deps"
    echo "aws.sh raw          - configure back to back instances"
    echo "aws.sh pmd          - configure testpmd"
    echo "aws.sh linux        - configure linux router"
    echo "aws.sh vpp [uio]    - configure vpp"
    echo "aws.sh test [NAME]  - run tests"
  fi
}

aws_test_cli $@

