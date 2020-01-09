#!/bin/bash

set -e

# ------------------------------

IDENTITY_FILE=~/nskrzypc-key.pem

MTU=1500 # 9001
TIME=20 # test duration

VM1_IP=10.0.0.110
VM1_IF=ens5

ROUTER_MANAGEMENT_IP=10.0.0.49

# ROUTER interface towards VM1
ROUTER_VM1_IF=ens6
ROUTER_VM1_IF_PCI=0000:00:06.0
ROUTER_VM1_IP=10.0.0.11
ROUTER_VM1_NAME=VirtualFunctionEthernet0/6/0

# ROUTER interface towards VM2
ROUTER_VM2_IF=ens7
ROUTER_VM2_IF_PCI=0000:00:07.0
ROUTER_VM2_IP=10.0.0.12
ROUTER_VM2_NAME=VirtualFunctionEthernet0/7/0

VM2_IP=10.0.0.113
VM2_IF=ens5

VPP_DIR=/home/ubuntu/vpp
VPP_RUN_DIR=/run/vpp
DPDK_DEVBIND=$VPP_DIR/build-root/install-vpp-native/external/sbin/dpdk-devbind
TESTPMD=$VPP_DIR/build-root/install-vpp-native/external/bin/testpmd
VPPBIN=$VPP_DIR/build-root/install-vpp-native/vpp/bin/vpp
VPPCTLBIN=$VPP_DIR/build-root/install-vpp-native/vpp/bin/vppctl
IGB_UIO_KO=$VPP_DIR/build-root/build-vpp-native/external/dpdk-19.08/x86_64-native-linuxapp-gcc/kmod/igb_uio.ko

# ------------------------------

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SCRIPTDIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"

run_ () {
  if [[ "$1" = "switch" ]]; then
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
  srun_ switch "ip link set $ROUTER_VM1_IF mtu $MTU"
  srun_ switch "ip link set $ROUTER_VM2_IF mtu $MTU"
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
  ROUTER_VM2_MAC=$(get_mac switch $ROUTER_VM2_IF)
  srun_ vm1 "arp -s $VM2_IP ${ROUTER_VM1_MAC//[$'\r']}"
  srun_ vm2 "arp -s $VM1_IP ${ROUTER_VM2_MAC//[$'\r']}"

  srun_ vm1 "ip link set $VM1_IF mtu $MTU"
  srun_ vm2 "ip link set $VM2_IF mtu $MTU"
  srun_ switch "ip link set $ROUTER_VM1_IF mtu $MTU"
  srun_ switch "ip link set $ROUTER_VM2_IF mtu $MTU"
}

install_deps ()
{
  srun_ vm1 "apt update && apt install -y iperf iperf3 traceroute"
  srun_ vm2 "apt update && apt install -y iperf iperf3 traceroute"
  srun_ switch "apt update && apt install -y iperf iperf3 traceroute make"
  run_ switch "git clone https://gerrit.fd.io/r/vpp" || true
  run_ switch "cd vpp && make install-dep"
  run_ switch "git apply ~/vpp-testenv/aws-test/vpp-dpdk.patch" || true
  run_ switch "cd vpp && make build-release"
}

sync_dns ()
{
  grep -q '^$VM1_IP' /etc/hosts && sudo sed -i 's/^$VM1_IP.*/$VM1_IP vm1/' /etc/hosts || echo '$VM1_IP vm1' | sudo tee -a /etc/hosts
  grep -q '^$VM2_IP' /etc/hosts && sudo sed -i 's/^$VM2_IP.*/$VM2_IP vm2/' /etc/hosts || echo '$VM2_IP vm2' | sudo tee -a /etc/hosts
  grep -q '^$ROUTER_MANAGEMENT_IP' /etc/hosts && sudo sed -i 's/^$ROUTER_MANAGEMENT_IP.*/$ROUTER_MANAGEMENT_IP switch/' /etc/hosts || echo '$SWITCH_IP switch' | sudo tee -a /etc/hosts
  srun_ vm1 "
grep -q '^$VM1_IP' /etc/hosts && sudo sed -i 's/^$VM1_IP.*/$VM1_IP vm1/' /etc/hosts || echo '$VM1_IP vm1' | sudo tee -a /etc/hosts
grep -q '^$VM2_IP' /etc/hosts && sudo sed -i 's/^$VM2_IP.*/$VM2_IP vm2/' /etc/hosts || echo '$VM2_IP vm2' | sudo tee -a /etc/hosts
grep -q '^$ROUTER_MANAGEMENT_IP' /etc/hosts && sudo sed -i 's/^$ROUTER_MANAGEMENT_IP.*/$ROUTER_MANAGEMENT_IP switch/' /etc/hosts || echo '$SWITCH_IP switch' | sudo tee -a /etc/hosts"
  srun_ vm2 "
grep -q '^$VM1_IP' /etc/hosts && sudo sed -i 's/^$VM1_IP.*/$VM1_IP vm1/' /etc/hosts || echo '$VM1_IP vm1' | sudo tee -a /etc/hosts
grep -q '^$VM2_IP' /etc/hosts && sudo sed -i 's/^$VM2_IP.*/$VM2_IP vm2/' /etc/hosts || echo '$VM2_IP vm2' | sudo tee -a /etc/hosts
grep -q '^$ROUTER_MANAGEMENT_IP' /etc/hosts && sudo sed -i 's/^$ROUTER_MANAGEMENT_IP.*/$ROUTER_MANAGEMENT_IP switch/' /etc/hosts || echo '$SWITCH_IP switch' | sudo tee -a /etc/hosts"
}

# BPS=$(cat ~/$1.P$NTHREAD.run$RUN.client.json | jq '.end.sum_received.bits_per_second / 1000000000')
test_client ()
{
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

configure_vpp ()
{
  if [[ "$1" = "uio" ]]; then
    srun_ switch "modprobe uio"
    srun_ switch "insmod $IGB_UIO_KO wc_activate=1" || true
    DPDK_DRIVER="igb_uio"
  else
    srun_ switch "modprobe vfio-pci"
    DPDK_DRIVER="vfio-pci"
  fi
  echo 1 | srun_ switch "tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode"
  srun_ switch "mkdir -p $VPP_RUN_DIR"
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
  echo "
unix {
  interactive
  log $VPP_RUN_DIR/vpp.log
  cli-listen $VPP_RUN_DIR/cli.sock
  exec $VPP_RUN_DIR/startup.conf
}
cpu {
  main-core 0
  corelist-workers 1-4
}
dpdk {
  uio-driver $DPDK_DRIVER
  dev $ROUTER_VM1_IF_PCI { num-rx-queues 4 }
  dev $ROUTER_VM2_IF_PCI { num-rx-queues 4 }
}
" | srun_ switch tee $VPP_RUN_DIR/vpp.conf > /dev/null
  srun_ switch "ln -s $VPPCTLBIN /usr/local/bin/vppctl" || true
  ROUTER_VM1_MAC=$(get_mac switch $ROUTER_VM1_IF)
  ROUTER_VM2_MAC=$(get_mac switch $ROUTER_VM2_IF)
  srun_ vm1 "arp -s $VM2_IP ${ROUTER_VM1_MAC//[$'\r']}"
  srun_ vm2 "arp -s $VM1_IP ${ROUTER_VM2_MAC//[$'\r']}"
  srun_ vm1 "ip link set $VM1_IF mtu $MTU"
  srun_ vm2 "ip link set $VM2_IF mtu $MTU"

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

aws_test_cli ()
{
  if [[ "$1" = "dns" ]]; then
    sync_dns
  elif [[ "$1" = "sync" ]] && [[ "$2" != "" ]] ; then
    scp $SCRIPTDIR/* $2:~/
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
  elif [[ "$1" = "test" ]]; then
    test_client ${@:2}
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

