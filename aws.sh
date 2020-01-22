#!/bin/bash

set -e

# ------------------------------

IDENTITY_FILE=~/nskrzypc-key.pem

MTU=${MTU-1500}
WRK=${WRK-4} # N workers
TIME=${TIME-20} # test duration
NRUN=${NRUN-3} # Number of test runs
CP=${CP-""} # compact workers on one thread
BIDI=${BIDI-""} # bidirectional iperf3 (one out of two is reversed)
AES=${AES-256} # aes-gcm-128 or aes-gcm-256
LLQ=${LLQ-""} # 1 ti enable LLQ

VM1_IP=20.0.2.1
VM1_IP_PREFIX=20.0.2/24
VM1_LAST_IP=20.0.2.100
VM1_IF=ens6

VM1_MAC=02:a6:3b:7c:8e:7c
ROUTER_VM1_MAC=02:f6:51:84:6a:a2
ROUTER_VM2_MAC=02:c2:c6:31:b4:16
ROUTER2_VM1_MAC=02:1c:0d:2a:ab:1a
ROUTER2_VM2_MAC=02:59:9f:b7:3e:06
VM2_MAC=02:56:5b:e5:38:22

VM1_MANAGEMENT_IP=20.0.1.1
ROUTER_MANAGEMENT_IP=20.0.8.2
ROUTER2_MANAGEMENT_IP=20.0.8.3
VM2_MANAGEMENT_IP=20.0.1.4

# ROUTER interface towards VM1
ROUTER_VM1_IF=ens6
ROUTER_VM1_IF_PCI=0000:00:06.0
ROUTER_VM1_IP=20.0.3.1
ROUTER_VM1_NAME=VirtualFunctionEthernet0/6/0

# ROUTER interface towards VM2
ROUTER_VM2_IF=ens7
ROUTER_VM2_IF_PCI=0000:00:07.0
ROUTER_VM2_IP=20.0.4.1
ROUTER_VM2_LAST_IP=20.0.4.100
ROUTER_VM2_NAME=VirtualFunctionEthernet0/7/0

# ROUTER interface towards VM1
ROUTER2_VM1_IF=ens6
ROUTER2_VM1_IF_PCI=0000:00:06.0
ROUTER2_VM1_IP=20.0.5.1
ROUTER2_VM1_LAST_IP=20.0.5.100
ROUTER2_VM1_NAME=VirtualFunctionEthernet0/6/0

# ROUTER interface towards VM2
ROUTER2_VM2_IF=ens7
ROUTER2_VM2_IF_PCI=0000:00:07.0
ROUTER2_VM2_IP=20.0.6.1
ROUTER2_VM2_NAME=VirtualFunctionEthernet0/7/0

VM2_IP=20.0.7.1
VM2_IP_PREFIX=20.0.7/24
VM2_LAST_IP=20.0.7.100
VM2_IF=ens6

if [[ "$AES" = "256" ]]; then
  CRYPTO_KEY=6541686776336961656264656f6f65796541686776336961656264656f6f6579
  CRYPTO_ALG=aes-gcm-256
else
  CRYPTO_KEY=6541686776336961656264656f6f6579
  CRYPTO_ALG=aes-gcm-128
fi

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
  sudo modprobe vfio-pci
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  sudo $DPDK_DEVBIND --force -b vfio-pci $ROUTER_VM1_IF_PCI
  sudo $DPDK_DEVBIND --force -b vfio-pci $ROUTER_VM2_IF_PCI
  sudo sysctl -w vm.nr_hugepages=1024

  sudo $TESTPMD                         \
    -w $ROUTER_VM1_IF_PCI               \
    -w $ROUTER_VM2_IF_PCI               \
    -l 0,1,2,3,4,5                      \
    -- -a                               \
    --forward-mode=mac                  \
    --burst=32                          \
    --eth-peer=0,${VM1_MAC//[$'\r']}    \
    --eth-peer=1,${VM2_MAC//[$'\r']}    \
    --rss                               \
    --rxq=4                             \
    --txq=4                             \
    --nb-cores=4
}

configure_vm1 ()
{
  sudo ip link set $VM1_IF down
  sudo ip link set $VM1_IF up
  sudo ip addr flush dev $VM1_IF
  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    sudo ip addr add ${VM1_IP_IT[$i]}/32 dev $VM1_IF || true
  done
  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    sudo arp -i $VM1_IF -s ${VM2_IP_IT[$i]} ${1//[$'\r']}
  done
  sudo ip link set $VM1_IF mtu $MTU
  sudo ip route add 20.0.7.0/24 dev $VM1_IF
}

configure_vm2 ()
{
  sudo ip link set $VM2_IF down
  sudo ip link set $VM2_IF up
  sudo ip addr flush dev $VM2_IF
  for ((i = 0; i < ${#VM1_IP_IT[@]}; i++)); do
    sudo ip addr add ${VM2_IP_IT[$i]}/32 dev $VM2_IF || true
  done
  for ((i = 0; i < ${#VM1_IP_IT[@]}; i++)); do
    sudo arp -i $VM2_IF -s ${VM1_IP_IT[$i]} ${1//[$'\r']}
  done
  sudo ip link set $VM2_IF mtu $MTU
  sudo ip route add 20.0.2.0/24 dev $VM2_IF
}

configure_linux_router ()
{
  sudo ip link set $ROUTER_VM1_IF up
  sudo ip link set $ROUTER_VM2_IF up

  sudo ip addr add $ROUTER_VM1_IP dev $ROUTER_VM1_IF || true
  sudo ip addr add $ROUTER_VM2_IP dev $ROUTER_VM2_IF || true
  sudo ip route add $VM1_IP_PREFIX via $ROUTER_VM1_IP || true
  sudo ip route add $VM2_IP_PREFIX via $ROUTER_VM2_IP || true
  sudo sysctl net.ipv4.ip_forward=1

  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    sudo arp -i $ROUTER_VM1_IF -s ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
    sudo arp -i $ROUTER_VM2_IF -s ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
  done

  sudo ip link set $ROUTER_VM1_IF mtu $MTU
  sudo ip link set $ROUTER_VM2_IF mtu $MTU
}

install_deps ()
{
  if [[ "$ME" = "vm1" ]] || [[ "$ME" = "vm2" ]]; then
    sudo apt update && sudo apt install -y iperf iperf3 traceroute
  else
    sudo apt update && sudo apt install -y iperf iperf3 traceroute make python linux-tools-$(uname -r) linux-tools-generic
    git clone https://gerrit.fd.io/r/vpp || true
    cd vpp
    git fetch "https://gerrit.fd.io/r/vpp" refs/changes/89/24289/1 && git checkout FETCH_HEAD
    git apply ~/vpp-dpdk.patch
    git apply ~/dpdk-mq.patch
    make install-dep
    make build-release
  fi
}

sync_dns ()
{
  echo "Syncing hostnames"
  grep -q "^$VM1_MANAGEMENT_IP" /etc/hosts && sudo sed -i "s/^$VM1_MANAGEMENT_IP.*/$VM1_MANAGEMENT_IP vm1/" /etc/hosts || echo "$VM1_MANAGEMENT_IP vm1" | sudo tee -a /etc/hosts
  grep -q "^$VM2_MANAGEMENT_IP" /etc/hosts && sudo sed -i "s/^$VM2_MANAGEMENT_IP.*/$VM2_MANAGEMENT_IP vm2/" /etc/hosts || echo "$VM2_MANAGEMENT_IP vm2" | sudo tee -a /etc/hosts
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
    FNAME="$1.P$NTHREAD.run$RUN"
    run_ $VM1_MANAGEMENT_IP "nohup iperf3 -s -D -I ~/iperf3.pid --logfile ~/$FNAME.server > /dev/null 2>&1" > /dev/null 2>&1
    iperf3 -c vm1 -i 1 -t $TIME -P$NTHREAD ${@:2} > ~/$FNAME.client
    run_ $VM1_MANAGEMENT_IP 'kill `cat ~/iperf3.pid`' > /dev/null 2>&1
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
  mkdir -p ~/currentrun
  run_ $VM1_MANAGEMENT_IP "mkdir -p ~/currentrun"
  srun_ $VM1_MANAGEMENT_IP "pkill iperf3" > /dev/null 2>&1 || true
  echo "Testing with $NFORKS iperfs, ${TIME}s per test"
  NTHREAD=1
  for RUN in $(seq $NRUN) ; do
  for ((fork = 0; fork < $NFORKS; fork++)); do
    FNAME="currentrun/$1.${NFORKS}t.P$NTHREAD.run$RUN.fork$fork"
    run_ $VM1_MANAGEMENT_IP "nohup iperf3 -s -B ${VM1_IP_IT[$fork]} -D -I ~/iperf3.fork$fork.pid --logfile ~/$FNAME.server > /dev/null 2>&1" > /dev/null 2>&1
  done
  for ((fork = 0; fork < $NFORKS; fork++)); do
    FNAME="currentrun/$1.${NFORKS}t.P$NTHREAD.run$RUN.fork$fork"
    if [[ "$BIDI" != "" ]] && [[ $((fork%2)) = 1 ]]; then
          REVERSED="-R"
    else
          REVERSED=""
    fi
    iperf3 $REVERSED -c ${VM1_IP_IT[$fork]} -B ${VM2_IP_IT[$fork]} -i 1 -t $TIME -P$NTHREAD ${@:3} --logfile ~/$FNAME.client > /dev/null 2>&1 &
    echo "$!" > ~/iperf3.fork$fork.pid
  done
  BPS=0
  for ((fork = 0; fork < $NFORKS; fork++)); do
    FNAME="currentrun/$1.${NFORKS}t.P$NTHREAD.run$RUN.fork$fork"
    if [[ "$BIDI" != "" ]] && [[ $((fork%2)) = 1 ]]; then
          REVERSED="-R"
    else
          REVERSED=""
    fi
    wait $(cat ~/iperf3.fork$fork.pid)
    rm ~/iperf3.fork$fork.pid
    sed -i -e "1i COMMAND::iperf3 $REVERSED -c ${VM1_IP_IT[$fork]} -B ${VM2_IP_IT[$fork]} -i 1 -t $TIME -P$NTHREAD ${@:3}" ~/$FNAME.client
    run_ $VM1_MANAGEMENT_IP "kill \$(cat ~/iperf3.fork$fork.pid)" > /dev/null 2>&1
    BPSG_=$(tail -n 3 ~/$FNAME.client | head -1 | egrep -o "[0-9\.]+ Gbits/s" | egrep -o "[0-9\.]+" || echo "0")
    BPSM_=$(tail -n 3 ~/$FNAME.client | head -1 | egrep -o "[0-9\.]+ Mbits/s" | egrep -o "[0-9\.]+" || echo "0")
    BPSK_=$(tail -n 3 ~/$FNAME.client | head -1 | egrep -o "[0-9\.]+ Kbits/s" | egrep -o "[0-9\.]+" || echo "0")
    BPS=$(echo $BPS $BPSG_ $BPSM_ $BPSK_ | awk '{print $1 + $2 + ($3 / 1000) + ($4 / 1000000)}')
  done
  echo "$1.${NFORKS}t.P$NTHREAD.run$RUN : $BPS Gbits/s"
  done
}

create_vpp_startup_conf ()
{
  if [[ "$WRK" = "1" ]]; then
    CORELIST_WORKERS="1"
  else
    CORELIST_WORKERS="1-$WRK"
  fi
  sudo mkdir -p $VPP_RUN_DIR
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
  dev default { num-rx-queues $WRK num-rx-desc 1024 }
  dev $ROUTER_VM1_IF_PCI
  dev $ROUTER_VM2_IF_PCI
}
buffers {
   buffers-per-numa 262144
   default data-size 8192
}
" | sudo tee $VPP_RUN_DIR/vpp.conf > /dev/null
  sudo sysctl -w vm.nr_hugepages=2048
}

configure_vpp_nic_drivers ()
{
  if [[ "$1" = "uio" ]]; then
    sudo modprobe uio
    sudo insmod $IGB_UIO_KO wc_activate=1 || true
    DPDK_DRIVER="igb_uio"
  else
    sudo modprobe vfio-pci
    DPDK_DRIVER="vfio-pci"
  fi
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
}

configure_vpp ()
{
  configure_vpp_nic_drivers $1
  create_vpp_startup_conf

  # ----------------- Startup CLIs -----------------
  echo "
set int state $ROUTER_VM1_NAME up
set int state $ROUTER_VM2_NAME up
set int ip address $ROUTER_VM1_NAME 127.0.0.1/32
set int ip address $ROUTER_VM2_NAME 127.0.0.2/32
ip route add $VM1_IP/24 via $ROUTER_VM1_NAME
ip route add $VM2_IP/24 via $ROUTER_VM2_NAME

set int mtu $MTU $ROUTER_VM1_NAME
set int mtu $MTU $ROUTER_VM2_NAME
" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    echo "
set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
set ip neighbor $ROUTER_VM2_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
" | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  done

  run_vpp
}

run_vpp ()
{
  sudo ln -s $VPPCTLBIN /usr/local/bin/vppctl || true
  echo "LLQ is $LLQ"
  sudo DPDK_ENA_LLQ_ENABLE=$LLQ $VPPBIN -c $VPP_RUN_DIR/vpp.conf
  if [[ "$CP" != "" ]]; then
    echo "compacting vpp workers"
    sleep 1
    pgrep -w vpp | (local i=0; while read thr; do sudo taskset -p -c $((i/2)) $thr; i=$((i+1)); done)
    echo "done"
  fi
}

unconfigure_all ()
{
  sudo pkill vpp || true
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI
  sudo ip link set $ROUTER_VM1_IF down
  sudo ip link set $ROUTER_VM2_IF down
}

sync ()
{
  rsync -avz              \
    --exclude=results     \
    --exclude=.gitignore  \
    --exclude=.git        \
    $SCRIPTDIR/ $1:~/
  ssh $1 -t "echo $1 > .me"
}

configure_vpp_ipsec_1 ()
{
  sudo pkill vpp || true
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI
  sudo ip link set $ROUTER_VM1_IF down
  sudo ip link set $ROUTER_VM2_IF down

  configure_vpp_nic_drivers $1
  create_vpp_startup_conf

  # ----------------- Startup CLIs -----------------
  echo "
set int state $ROUTER_VM1_NAME up
set int state $ROUTER_VM2_NAME up
set int ip address $ROUTER_VM1_NAME $ROUTER_VM1_IP/32

ip route add $ROUTER2_VM1_IP/32 via $ROUTER_VM2_NAME
" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    echo "
set int ip address $ROUTER_VM2_NAME ${ROUTER_VM2_IP_IT[$i]}/32
create ipip tunnel src ${ROUTER_VM2_IP_IT[$i]} dst ${ROUTER2_VM1_IP_IT[$i]}

ipsec sa add 2$i spi 20$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
ipsec sa add 3$i spi 30$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
ipsec tunnel protect ipip$i sa-in 2$i sa-out 3$i

set int state ipip$i up
set int ip addr ipip$i 127.0.0.$((i+1))/32
set ip neighbor $ROUTER_VM2_NAME ${ROUTER2_VM1_IP_IT[$i]} ${ROUTER2_VM1_MAC//[$'\r']}
set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}

ip route add ${VM1_IP_IT[$i]}/32 via $ROUTER_VM1_NAME
ip route add ${VM2_IP_IT[$i]}/32 via ipip$i
ip route add ${ROUTER2_VM1_IP_IT[$i]}/32 via $ROUTER_VM2_NAME
" | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  done

  run_vpp
}

configure_vpp_ipsec_2 ()
{
  sudo pkill vpp || true
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI
  sudo ip link set $ROUTER_VM1_IF down
  sudo ip link set $ROUTER_VM2_IF down

  configure_vpp_nic_drivers $1
  create_vpp_startup_conf

  # ----------------- Startup CLIs -----------------
  echo "
set int state $ROUTER2_VM1_NAME up
set int state $ROUTER2_VM2_NAME up
set int ip address $ROUTER2_VM2_NAME $ROUTER2_VM2_IP/32

" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    echo "
set int ip address $ROUTER2_VM1_NAME ${ROUTER2_VM1_IP_IT[$i]}/32
create ipip tunnel src ${ROUTER2_VM1_IP_IT[$i]} dst ${ROUTER_VM2_IP_IT[$i]}

ipsec sa add 2$i spi 20$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
ipsec sa add 3$i spi 30$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
ipsec tunnel protect ipip$i sa-in 3$i sa-out 2$i

set int state ipip$i up
set int ip addr ipip$i 127.0.0.$((i+1))/32
set ip neighbor $ROUTER2_VM1_NAME ${ROUTER_VM2_IP_IT[$i]} ${ROUTER_VM2_MAC//[$'\r']}
set ip neighbor $ROUTER2_VM2_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}

ip route add ${VM2_IP_IT[$i]}/32 via $ROUTER2_VM2_NAME
ip route add ${VM1_IP_IT[$i]}/32 via ipip$i
ip route add ${ROUTER_VM2_IP_IT[$i]}/32 via $ROUTER2_VM1_NAME
" | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  done

  run_vpp
}

aws_test_cli ()
{
  if [[ "$1" = "dns" ]]; then
    sync_dns
  elif [[ "$1" = "sync" ]]; then
    sync $2.vm1
    sync $2.vm2
    sync $2.switch
    sync $2.switch2
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
  # VM configuration
  elif [[ "$1 $2" = "vm1 router" ]]; then
    configure_vm1 $ROUTER_VM1_MAC
  elif [[ "$1 $2" = "vm2 router" ]]; then
    configure_vm2 $ROUTER_VM2_MAC
  elif [[ "$1 $2" = "vm1 ipsec" ]]; then
    configure_vm1 $ROUTER_VM1_MAC
  elif [[ "$1 $2" = "vm2 ipsec" ]]; then
    configure_vm2 $ROUTER2_VM2_MAC
  elif [[ "$1 $2" = "vm1 raw" ]]; then
    configure_vm1 $VM2_MAC
  elif [[ "$1 $2" = "vm2 raw" ]]; then
    configure_vm2 $VM1_MAC
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

