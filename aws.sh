#!/bin/bash

set -e

if [[ "$X" != "" ]]; then
  set -x
fi

# ------------------------------


MTU=${MTU-1500}
WRK=${WRK-4} # N workers
CP=${CP-""} # compact workers on one thread
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


# VM1_MAC=02:bd:5b:aa:df:a5
# ROUTER_VM1_MAC=02:45:d3:96:a4:9b
# ROUTER_VM2_MAC=02:c1:02:72:5f:73
# ROUTER2_VM1_MAC=02:eb:0d:71:55:0f
# ROUTER2_VM2_MAC=02:73:7a:a5:4c:65
# VM2_MAC=02:bc:f7:69:06:95

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
elif [[ "$AES" = "CBC128" ]]; then
  CRYPTO_KEY=6541686776336961656264656f6f6579
  CRYPTO_ALG=aes-cbc-128
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

# IP_CNT=${#VM1_IP_IT[@]}
IP_CNT=4

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
  NXT_HOP=$1
  sudo ip link set $VM1_IF down
  sudo ip link set $VM1_IF up
  sudo ip addr flush dev $VM1_IF
  for ((i = 0; i < ${IP_CNT}; i++)); do
    sudo ip addr add ${VM1_IP_IT[$i]}/24 dev $VM1_IF || true
  done
  for ((i = 0; i < ${IP_CNT}; i++)); do
    sudo arp -i $VM1_IF -s ${VM2_IP_IT[$i]} ${NXT_HOP//[$'\r']}
  done
  sudo ip link set $VM1_IF mtu $MTU
  sudo ip route add 20.0.7.0/24 dev $VM1_IF
}

configure_vm2 ()
{
  NXT_HOP=$1
  sudo ip link set $VM2_IF down
  sudo ip link set $VM2_IF up
  sudo ip addr flush dev $VM2_IF
  for ((i = 0; i < ${#VM1_IP_IT[@]}; i++)); do
    sudo ip addr add ${VM2_IP_IT[$i]}/24 dev $VM2_IF || true
  done
  for ((i = 0; i < ${#VM1_IP_IT[@]}; i++)); do
    sudo arp -i $VM2_IF -s ${VM1_IP_IT[$i]} ${NXT_HOP//[$'\r']}
  done
  sudo ip link set $VM2_IF mtu $MTU
  sudo ip route add 20.0.2.0/24 dev $VM2_IF
}

aws_configure_linux_router ()
{
  # Cleanup
  sudo pkill vpp || true
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI
  if [[ "$ROUTER_VM2_IF_PCI" != "" ]]; then
    sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI
  fi
  sudo ip link set $ROUTER_VM1_IF down
  sudo ip link set $ROUTER_VM1_IF up
  sudo ip link set $ROUTER_VM2_IF down
  sudo ip link set $ROUTER_VM2_IF up
  sudo ip addr flush dev $ROUTER_VM1_IF
  sudo ip addr flush dev $ROUTER_VM2_IF

  sudo sysctl net.ipv4.ip_forward=1

  if [[ "$1" = "1" ]] ; then
    sudo ip addr add $ROUTER_VM1_IP/24 dev $ROUTER_VM1_IF
    sudo ip addr add $ROUTER_VM2_IP/24 dev $ROUTER_VM2_IF
    sudo ip route add $VM1_IP_PREFIX via $ROUTER_VM1_IP || true
    sudo ip route add $VM2_IP_PREFIX via $ROUTER_VM2_IP || true
    for ((i = 0; i < ${IP_CNT}; i++)); do
      sudo arp -i $ROUTER_VM1_IF -s ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
      sudo arp -i $ROUTER_VM2_IF -s ${VM2_IP_IT[$i]} ${ROUTER2_VM1_MAC//[$'\r']}
    done
  elif [[ "$1" = "2" ]] ; then
    sudo ip addr add $ROUTER2_VM1_IP/24 dev $ROUTER_VM1_IF || true
    sudo ip addr add $ROUTER2_VM2_IP/24 dev $ROUTER_VM2_IF || true
    sudo ip route add $VM1_IP_PREFIX via $ROUTER2_VM1_IP || true
    sudo ip route add $VM2_IP_PREFIX via $ROUTER2_VM2_IP || true
    for ((i = 0; i < ${IP_CNT}; i++)); do
      sudo arp -i $ROUTER_VM1_IF -s ${VM1_IP_IT[$i]} ${ROUTER_VM2_MAC//[$'\r']}
      sudo arp -i $ROUTER_VM2_IF -s ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
    done
  else
    echo "One hop"
    sudo ip addr add $ROUTER_VM1_IP/24 dev $ROUTER_VM1_IF || true
    sudo ip addr add $ROUTER_VM2_IP/24 dev $ROUTER_VM2_IF || true
    sudo ip route add $VM1_IP_PREFIX via $ROUTER_VM1_IP || true
    sudo ip route add $VM2_IP_PREFIX via $ROUTER_VM2_IP || true

    for ((i = 0; i < ${IP_CNT}; i++)); do
      sudo arp -i $ROUTER_VM1_IF -s ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
      sudo arp -i $ROUTER_VM2_IF -s ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
    done
  fi

}

install_deps ()
{
  if [[ "$1" = "vm1" ]] || [[ "$1" = "vm2" ]]; then
    sudo apt update && sudo apt install -y iperf iperf3 traceroute
  else
    sudo apt update && sudo apt install -y iperf iperf3 traceroute make python linux-tools-$(uname -r) linux-tools-generic
    git clone https://gerrit.fd.io/r/vpp || true
    cd vpp
    git fetch "https://gerrit.fd.io/r/vpp" refs/changes/89/24289/1 && git checkout FETCH_HEAD
    git apply ~/test/patch/vpp-dpdk.patch
    git apply ~/test/patch/dpdk-mq.patch
    make install-dep
    make build-release
  fi
}

create_vpp_startup_conf ()
{
  if [[ "$WRK" = "1" ]]; then
    CORELIST_WORKERS="corelist-workers 1"
  elif [[ "$WRK" = "0" ]]; then
    CORELIST_WORKERS="workers 0"
  else
    CORELIST_WORKERS="corelist-workers 1-$WRK"
  fi
  if [[ "$ROUTER_VM2_IF_PCI" != "" ]]; then
    IF_PCI2="dev $ROUTER_VM2_IF_PCI"
  else
    IF_PCI2=""
  fi
  if [[ "$BUILD" != "" ]]; then
    echo "Using build-$BUILD"
    cd $VPP_DIR/build-root
    rm install-vpp-native
    ln -s build-$BUILD install-vpp-native
    cd ~
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
  $CORELIST_WORKERS
}
dpdk {
  dev default { num-rx-queues 8 num-rx-desc 1024 }
  uio-driver $DPDK_DRIVER
  dev $ROUTER_VM1_IF_PCI
  $IF_PCI2
}
buffers {
   buffers-per-numa 131072
   default data-size 8192
}
" | sudo tee $VPP_RUN_DIR/vpp.conf > /dev/null
  sudo sysctl -w vm.nr_hugepages=1024
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

" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${IP_CNT}; i++)); do
    echo "
set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
set ip neighbor $ROUTER_VM2_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
" | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  done

  run_vpp
}

configure_vpp1 ()
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

" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${IP_CNT}; i++)); do
    echo "
set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
set ip neighbor $ROUTER_VM2_NAME ${VM2_IP_IT[$i]} ${ROUTER2_VM1_MAC//[$'\r']}
" | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  done

  run_vpp
}

configure_vpp2 ()
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

" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${IP_CNT}; i++)); do
    echo "
set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${ROUTER_VM2_MAC//[$'\r']}
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
  if [[ "$ROUTER_VM2_IF_PCI" != "" ]]; then
    sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI
  fi
  sudo ip link set $ROUTER_VM1_IF down
  sudo ip link set $ROUTER_VM2_IF down
}

configure_vpp_ipsec_1 ()
{
  sudo pkill vpp || true
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI
  if [[ "$ROUTER_VM2_IF_PCI" != "" ]]; then
    sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI
  fi
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

  for ((i = 0; i < ${IP_CNT}; i++)); do
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
  sudo $DPDK_DEVBIND --force -b ena $ROUTER2_VM1_IF_PCI
  if [[ "$ROUTER2_VM2_IF_PCI" != "" ]]; then
    sudo $DPDK_DEVBIND --force -b ena $ROUTER2_VM2_IF_PCI
  fi
  sudo ip link set $ROUTER2_VM1_IF down
  sudo ip link set $ROUTER2_VM2_IF down

  configure_vpp_nic_drivers $1
  create_vpp_startup_conf

  # ----------------- Startup CLIs -----------------
  echo "
set int state $ROUTER2_VM1_NAME up
set int state $ROUTER2_VM2_NAME up
set int ip address $ROUTER2_VM2_NAME $ROUTER2_VM2_IP/32

" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  for ((i = 0; i < ${IP_CNT}; i++)); do
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
    unconfigure_all
    configure_test_pmd
  elif [[ "$1" = "linux" ]]; then
    aws_configure_linux_router ${@:2}
  elif [[ "$1 $2" = "vpp 1" ]]; then
    unconfigure_all
    configure_vpp1 ${@:3}
  elif [[ "$1 $2" = "vpp 2" ]]; then
    unconfigure_all
    configure_vpp2 ${@:3}
  elif [[ "$1" = "vpp" ]]; then
    unconfigure_all
    configure_vpp ${@:2}
  elif [[ "$1 $2" = "ipsec 1" ]]; then
    configure_vpp_ipsec_1 ${@:3}
  elif [[ "$1 $2" = "ipsec 2" ]]; then
    configure_vpp_ipsec_2 ${@:3}
  # VM configuration
  elif [[ "$1 $2" = "vm1 one" ]]; then
    configure_vm1 $ROUTER_VM1_MAC
  elif [[ "$1 $2" = "vm2 one" ]]; then
    configure_vm2 $ROUTER_VM2_MAC
  elif [[ "$1 $2" = "vm1 two" ]]; then
    configure_vm1 $ROUTER_VM1_MAC
  elif [[ "$1 $2" = "vm2 two" ]]; then
    configure_vm2 $ROUTER2_VM2_MAC
  elif [[ "$1 $2" = "vm1 zero" ]]; then
    configure_vm1 $VM2_MAC
  elif [[ "$1 $2" = "vm2 zero" ]]; then
    configure_vm2 $VM1_MAC

  else
    echo "Usage:"
    echo "aws.sh install                        - install deps"
    echo "aws.sh vm[1|2] [zero|one|two]         - configure VMs with zero/one/two hops"
    echo "aws.sh pmd                            - configure testpmd forwarding (one hop)"
    echo "aws.sh linux                          - configure linux router (one hop)"
    echo "aws.sh vpp [uio]                      - configure vpp (one hop)"
    echo "aws.sh ipsec [1|2]                    - configure ipsec (two hops)"
  fi
}

aws_test_cli $@

