#!/bin/bash

set -e

if [[ "$X" != "" ]]; then
  set -x
fi

# ------------------------------

IDENTITY_FILE=~/nskrzypc-key.pem

MTU=${MTU-1500}
WRK=${WRK-1} # N workers
CP=${CP-""} # compact workers on one thread
AES=${AES-256} # aes-gcm-128 or aes-gcm-256
LLQ=${LLQ-""} # 1 ti enable LLQ

VM1_BASE_IP=20.0.2.11
VM1_IP=20.0.2.64
VM1_IP_PREFIX=20.0.2.64/26
VM1_LAST_IP=20.0.2.127
VM1_IF=eth1

VM1_MANAGEMENT_IP=20.0.1.4
ROUTER_MANAGEMENT_IP=20.0.1.6
ROUTER2_MANAGEMENT_IP=20.0.1.7
VM2_MANAGEMENT_IP=20.0.1.5

AZURE_RT_MAC=12:34:56:78:9a:bc

# ROUTER interface towards VM1
ROUTER_VM1_IF=eth1
ROUTER_VM1_IF_PCI=0002:00:02.0 # rename6
ROUTER_VM1_IP=20.0.2.10
ROUTER_VM1_NAME=FailsafeEthernet0

# ROUTER interface towards VM2
ROUTER_VM2_IF=eth2
ROUTER_VM2_IF_PCI=0003:00:02.0 # rename7
ROUTER_VM2_BASE_IP=20.0.4.10
ROUTER_VM2_IP=20.0.4.64
ROUTER_VM2_IP_PREFIX=20.0.4.64/26
ROUTER_VM2_LAST_IP=20.0.4.127
ROUTER_VM2_NAME=FailsafeEthernet2

# ROUTER interface towards VM1
ROUTER2_VM1_IF=eth1
ROUTER2_VM1_IF_PCI=0000:00:06.0
ROUTER2_VM1_BASE_IP=20.0.4.12
ROUTER2_VM1_IP=20.0.4.128
ROUTER2_VM1_IP_PREFIX=20.0.4.128/26
ROUTER2_VM1_LAST_IP=20.0.4.191
ROUTER2_VM1_NAME=FailsafeEthernet0

# ROUTER interface towards VM2
ROUTER2_VM2_IF=eth2
ROUTER2_VM2_IF_PCI=0000:00:07.0
ROUTER2_VM2_IP=20.0.7.10
ROUTER2_VM2_NAME=FailsafeEthernet2

VM2_IP=20.0.7.64
VM2_BASE_IP=20.0.7.11
VM2_IP_PREFIX=20.0.7.64/26
VM2_LAST_IP=20.0.7.127
VM2_IF=eth1


VM2_BASE_IP2=20.0.4.13
VM2_IP2=20.0.4.192
VM2_IP2_PREFIX=20.0.4.192/26
VM2_LAST_IP2=20.0.4.255
VM2_IF2=eth2

VM2_BASE_IP3=20.0.2.13
VM2_IP3=20.0.2.192
VM2_IP3_PREFIX=20.0.2.192/26
VM2_LAST_IP3=20.0.2.255
VM2_IF3=eth3

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
VPP_LIB_DIR=$VPP_DIR/build-root/install-vpp-native/external/lib

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
VM2_IP2_IT=($(ip_it $VM2_IP2 $VM2_LAST_IP2))
VM2_IP3_IT=($(ip_it $VM2_IP3 $VM2_LAST_IP3))
ROUTER_VM2_IP_IT=($(ip_it $ROUTER_VM2_IP $ROUTER_VM2_LAST_IP))
ROUTER2_VM1_IP_IT=($(ip_it $ROUTER2_VM1_IP $ROUTER2_VM1_LAST_IP))

azure_configure_test_pmd ()
{
  sudo modprobe -a ib_uverbs
  sudo modprobe mlx4_ib
  sudo sysctl -w vm.nr_hugepages=1024

  azure_configure_linux_router $1 # Slow path for now

  sudo LD_LIBRARY_PATH=$VPP_LIB_DIR $TESTPMD  \
    -w $ROUTER_VM1_IF_PCI                     \
    -w $ROUTER_VM2_IF_PCI                     \
    -l 0,1,2,3,4,5                            \
    --                                        \
    -i \
    --eth-peer=1,${AZURE_RT_MAC//[$'\r']}     \
    --eth-peer=2,${AZURE_RT_MAC//[$'\r']}     \
    -a                                        \
    --forward-mode=mac                        \
    --burst=32                                \
    --rss                                     \
    --rxq=$WRK                                \
    --txq=$WRK                                \
    --nb-cores=$WRK
}

configure_vm1 ()
{
  # OK
  sudo ip link set $VM1_IF down
  sudo ip link set $VM1_IF up
  sudo ip route del $VM2_IP2_PREFIX || true
  sudo ip addr flush dev $VM1_IF

  for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
    sudo ip addr add ${VM1_IP_IT[$i]}/26 dev $VM1_IF || true
  done
  sudo ip route add $VM2_IP_PREFIX dev $VM1_IF via $ROUTER_VM1_IP || true
  sudo ip route add $VM2_IP2_PREFIX dev $VM1_IF via $ROUTER_VM1_IP || true
  sudo ip route add $VM2_IP3_PREFIX dev $VM1_IF via $VM2_BASE_IP3 || true

  sudo ip link set $VM1_IF mtu $MTU
}

configure_vm2 ()
{
  if [[ "$1" = "" ]]; then
     echo "please provide zero|one|two"
     exit 1
  fi
  # OK
  # if1
  sudo ip link set $VM2_IF down
  sudo ip link set $VM2_IF up
  sudo ip addr flush dev $VM2_IF

  # if2
  sudo ip link set $VM2_IF2 down
  sudo ip link set $VM2_IF2 up
  sudo ip addr flush dev $VM2_IF2

  # if3
  sudo ip link set $VM2_IF3 down
  sudo ip link set $VM2_IF3 up
  sudo ip addr flush dev $VM2_IF3

  sudo ip route del $VM1_IP_PREFIX || true

  for ((i = 0; i < ${#VM1_IP_IT[@]}; i++)); do
    sudo ip addr add ${VM2_IP_IT[$i]}/26 dev $VM2_IF || true
    sudo ip addr add ${VM2_IP2_IT[$i]}/26 dev $VM2_IF2 || true
    sudo ip addr add ${VM2_IP3_IT[$i]}/26 dev $VM2_IF3 || true
  done
  if [[ "$1" = "one" ]] ; then
    # one hop route to VM1
    sudo ip route add $VM1_IP_PREFIX dev $VM2_IF2 via $ROUTER_VM2_BASE_IP || true
  elif [[ "$1" = "zero" ]]; then
    # zero hop route to VM1
    sudo ip route add $VM1_IP_PREFIX dev $VM2_IF3 via $VM1_BASE_IP || true
  elif [[ "$1" = "two" ]]; then
    sudo ip route add $VM1_IP_PREFIX dev $VM2_IF via $ROUTER2_VM2_IP || true
  else
    echo "Wot ?"
  fi

  sudo ip link set $VM2_IF mtu $MTU
}

azure_configure_linux_router ()
{
  # OK
  sudo ip addr flush dev $ROUTER_VM1_IF
  sudo ip addr flush dev $ROUTER_VM2_IF

  if [[ "$1" = "1" ]] ; then
    sudo ip addr add $ROUTER_VM1_IP/24 dev $ROUTER_VM1_IF
    sudo ip addr add $ROUTER_VM2_BASE_IP/24 dev $ROUTER_VM2_IF

    sudo ip route add $VM1_IP_PREFIX dev $ROUTER_VM1_IF via $VM1_BASE_IP || true
    sudo ip route add $VM2_IP_PREFIX dev $ROUTER_VM2_IF via $ROUTER2_VM1_BASE_IP || true
  elif [[ "$1" = "2" ]] ; then
    sudo ip addr add $ROUTER2_VM1_BASE_IP/24 dev $ROUTER_VM1_IF
    sudo ip addr add $ROUTER2_VM2_IP/24 dev $ROUTER_VM2_IF

    sudo ip route add $VM1_IP_PREFIX dev $ROUTER_VM1_IF via $ROUTER_VM2_BASE_IP || true
    sudo ip route add $VM2_IP_PREFIX dev $ROUTER_VM2_IF via $VM2_BASE_IP || true
  else
    # One hop
    sudo ip addr add $ROUTER_VM1_IP/24 dev $ROUTER_VM1_IF
    sudo ip addr add $ROUTER_VM2_BASE_IP/24 dev $ROUTER_VM2_IF

    sudo ip route add $VM1_IP_PREFIX dev $ROUTER_VM1_IF via $VM1_BASE_IP || true
    sudo ip route add $VM2_IP2_PREFIX dev $ROUTER_VM2_IF via $VM2_BASE_IP2 || true
  fi

  sudo sysctl net.ipv4.ip_forward=1

  sudo ip link set $ROUTER_VM1_IF mtu $MTU
  sudo ip link set $ROUTER_VM2_IF mtu $MTU
}

install_deps ()
{
  if [[ "$1" = "vm1" ]] || [[ "$1" = "vm2" ]]; then
    sudo apt update && sudo apt install -y iperf iperf3 traceroute
  else
    sudo apt update && sudo apt install -y \
      iperf \
      iperf3 \
      traceroute \
      make \
      python \
      linux-tools-$(uname -r) \
      linux-tools-generic \
      libmnl-dev librdmacm-dev librdmacm1 build-essential libnuma-dev # dpdk
    git clone https://gerrit.fd.io/r/vpp || true
    cd vpp
    # git fetch "https://gerrit.fd.io/r/vpp" refs/changes/89/24289/1 && git checkout FETCH_HEAD
    git apply ~/test/patch/mlx4_pmd.patch
    make install-dep
    make build-release
  fi
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
  dev default { num-rx-queues $WRK num-rx-desc 1024 }
  dev $ROUTER_VM1_IF_PCI { name VM1_IF }
  dev $ROUTER_VM2_IF_PCI { name VM2_IF }
}
" | sudo tee $VPP_RUN_DIR/vpp.conf > /dev/null
}

configure_vpp ()
{
  sudo pkill vpp || true
  sudo modprobe -a ib_uverbs
  sudo modprobe mlx4_ib
  sudo sysctl -w vm.nr_hugepages=1024

  azure_configure_linux_router $1 # Slow path for now

  create_vpp_startup_conf

  echo "
    set int st VM1_IF up
    set int st VM2_IF up

    set int mtu $MTU VM1_IF
    set int mtu $MTU VM2_IF
  " | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  if [[ "$1" = "1" ]] ; then
    echo "
      set int ip addr VM1_IF $ROUTER_VM1_IP/24
      set int ip addr VM2_IF $ROUTER_VM2_BASE_IP/24

      set ip neighbor VM1_IF $VM1_BASE_IP ${AZURE_RT_MAC//[$'\r']}
      set ip neighbor VM2_IF $ROUTER2_VM1_BASE_IP ${AZURE_RT_MAC//[$'\r']}

      ip route add $VM1_IP_PREFIX via $VM1_BASE_IP VM1_IF
      ip route add $VM2_IP_PREFIX via $ROUTER2_VM1_BASE_IP VM2_IF
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  elif [[ "$1" = "2" ]] ; then
    echo "
      set int ip addr VM1_IF $ROUTER2_VM1_BASE_IP/24
      set int ip addr VM2_IF $ROUTER2_VM2_IP/24

      set ip neighbor VM1_IF $ROUTER_VM2_BASE_IP ${AZURE_RT_MAC//[$'\r']}
      set ip neighbor VM2_IF $VM2_BASE_IP ${AZURE_RT_MAC//[$'\r']}

      ip route add $VM1_IP_PREFIX via $ROUTER_VM2_BASE_IP VM1_IF
      ip route add $VM2_IP_PREFIX via $VM2_BASE_IP VM2_IF
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  else
    echo "
      set int ip addr VM1_IF $ROUTER_VM1_IP/24
      set int ip addr VM2_IF $ROUTER_VM2_BASE_IP/24
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    for ((i = 0; i < ${#VM2_IP_IT[@]}; i++)); do
      echo "
	set ip neighbor VM1_IF ${VM1_IP_IT[$i]} ${AZURE_RT_MAC//[$'\r']}
	set ip neighbor VM2_IF ${VM2_IP2_IT[$i]} ${AZURE_RT_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    done
  fi

  run_vpp
}

run_vpp ()
{
  sudo ln -s $VPPCTLBIN /usr/local/bin/vppctl || true
  echo "LLQ is $LLQ"
  sudo DPDK_ENA_LLQ_ENABLE=$LLQ \
    LD_LIBRARY_PATH=$VPP_LIB_DIR \
    $VPPBIN -c $VPP_RUN_DIR/vpp.conf
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
  if [[ "$1" = "install" ]]; then
    install_deps ${@:2}
  elif [[ "$1" = "pmd" ]]; then
    azure_configure_test_pmd ${@:2}
  elif [[ "$1" = "linux" ]]; then
    azure_configure_linux_router ${@:2}
  elif [[ "$1" = "vpp" ]]; then
    configure_vpp ${@:2}
  elif [[ "$1" = "ipsec1" ]]; then
    configure_vpp_ipsec_1 ${@:2}
  elif [[ "$1" = "ipsec2" ]]; then
    configure_vpp_ipsec_2 ${@:2}
  # VM configuration
  elif [[ "$1" = "vm1" ]]; then
    configure_vm1
  elif [[ "$1" = "vm2" ]]; then
    configure_vm2 $2
  else
    echo "Usage:"
    echo "aws.sh sync                                              - sync this script"
    echo "aws.sh install                                           - install deps"
    echo "aws.sh ptest [zero|one|two] [NAME] [Nparallel] [OPTIONS] - run tests"
  fi
}

aws_test_cli $@

