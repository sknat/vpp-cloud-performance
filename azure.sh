#!/bin/bash

MTU=${MTU-1500}
WRK=${WRK-1} # N workers
CP=${CP-""} # compact workers on one thread
AES=${AES-256} # aes-gcm-128 or aes-gcm-256
LLQ=${LLQ-""} # 1 ti enable LLQ

source $( dirname "${BASH_SOURCE[0]}" )/shared.sh

# ------------------------------

VM1_IP_IT=($(ip_it $VM1_IP $VM1_LAST_IP))
VM2_IP_IT=($(ip_it $VM2_IP $VM2_LAST_IP))
VM2_IP2_IT=($(ip_it $VM2_IP2 $VM2_LAST_IP2))
VM2_IP3_IT=($(ip_it $VM2_IP3 $VM2_LAST_IP3))
ROUTER_VM2_IP_IT=($(ip_it $ROUTER_VM2_IP $ROUTER_VM2_LAST_IP))
ROUTER2_VM1_IP_IT=($(ip_it $ROUTER2_VM1_IP $ROUTER2_VM1_LAST_IP))

# IP_CNT=${#VM1_IP_IT[@]}
IP_CNT=4

azure_configure_test_pmd ()
{
  sudo modprobe -a ib_uverbs
  sudo modprobe mlx4_ib
  sudo sysctl -w vm.nr_hugepages=1024

  # azure_configure_linux_router $1 # Slow path for now
  sudo ip addr flush dev $ROUTER_VM1_IF
  sudo ip addr flush dev $ROUTER_VM2_IF
  sudo sysctl net.ipv4.ip_forward=0

  sudo LD_LIBRARY_PATH=$VPP_LIB_DIR $TESTPMD  \
    -w $ROUTER_VM1_IF_PCI                     \
    -w $ROUTER_VM2_IF_PCI                     \
    --vdev="net_vdev_netvsc0,iface=eth1"      \
    --vdev="net_vdev_netvsc1,iface=eth2"      \
    -l 0,1,2,3,4,5                            \
    --                                        \
    -i \
    --eth-peer=2,${AZURE_RT_MAC//[$'\r']}     \
    --eth-peer=4,${AZURE_RT_MAC//[$'\r']}     \
    -a                                        \
    --forward-mode=mac                        \
    --burst=32                                \
    --rss                                     \
    --rxq=$WRK                                \
    --txq=$WRK                                \
    --nb-cores=$WRK
}

azure_configure_vm1 ()
{
  # OK
  sudo ip link set $VM1_IF down
  sudo ip link set $VM1_IF up
  sudo ip addr flush dev $VM1_IF

  for ((i = 0; i < $IP_CNT; i++)); do
    sudo ip addr add ${VM1_IP_IT[$i]}/26 dev $VM1_IF || true
  done
  sleep 1
  sudo ip route add $VM2_IP_PREFIX via $ROUTER_VM1_IP || true
  sudo ip route add $VM2_IP2_PREFIX via $ROUTER_VM1_IP || true
  sudo ip route add $VM2_IP3_PREFIX via $VM2_BASE_IP3 || true

  sudo ip link set $VM1_IF mtu $MTU
}

azure_configure_vm2 ()
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

  for ((i = 0; i < $IP_CNT; i++)); do
    sudo ip addr add ${VM2_IP_IT[$i]}/26 dev $VM2_IF || true
    sudo ip addr add ${VM2_IP2_IT[$i]}/26 dev $VM2_IF2 || true
    sudo ip addr add ${VM2_IP3_IT[$i]}/26 dev $VM2_IF3 || true
  done
  sleep 2
  if [[ "$1" = "one" ]] ; then
    # one hop route to VM1
    sudo ip route add $VM1_IP_PREFIX via $ROUTER_VM2_BASE_IP || true
  elif [[ "$1" = "zero" ]]; then
    # zero hop route to VM1
    sudo ip route add $VM1_IP_PREFIX via $VM1_BASE_IP || true
  elif [[ "$1" = "two" ]]; then
    sudo ip route add $VM1_IP_PREFIX via $ROUTER2_VM2_IP || true
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
    echo "One hop"
    sudo ip addr add $ROUTER_VM1_IP/24 dev $ROUTER_VM1_IF
    sudo ip addr add $ROUTER_VM2_BASE_IP/24 dev $ROUTER_VM2_IF

    sudo ip route add $VM1_IP_PREFIX dev $ROUTER_VM1_IF via $VM1_BASE_IP || true
    sudo ip route add $VM2_IP2_PREFIX dev $ROUTER_VM2_IF via $VM2_BASE_IP2 || true
  fi

  sudo sysctl net.ipv4.ip_forward=1

  sudo ip link set $ROUTER_VM1_IF mtu $MTU
  sudo ip link set $ROUTER_VM2_IF mtu $MTU
}

azure_install_deps ()
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
    sudo cp ~/test/patch/10-dtap.link /etc/systemd/network/10-dtap.link
  fi
}

azure_create_vpp_startup_conf ()
{
  if [[ "$WRK" = "1" ]]; then
    CORELIST_WORKERS="corelist-workers 1"
  elif [[ "$WRK" = "0" ]]; then
    CORELIST_WORKERS="workers 0"
  else
    CORELIST_WORKERS="corelist-workers 1-$WRK"
  fi
  sudo mkdir -p $VPP_RUN_DIR

  if [[ "$DBG" != "" ]]; then
    MODE="interactive"
  else
    MODE=""
  fi

  echo "
    unix {
      $MODE
      log $VPP_RUN_DIR/vpp.log
      cli-listen $VPP_RUN_DIR/cli.sock
      exec $VPP_RUN_DIR/startup.conf
    }
    cpu {
      main-core 0
      $CORELIST_WORKERS
    }
    dpdk {
      dev default { num-rx-queues $WRK num-rx-desc 1024 }
      vdev net_vdev_netvsc0,iface=eth1
      vdev net_vdev_netvsc2,iface=eth2
      dev $ROUTER_VM1_IF_PCI { name VM1_IF }
      dev $ROUTER_VM2_IF_PCI { name VM2_IF }
    }
    buffers {
      buffers-per-numa 131072
      default data-size 4096
    }
  " | sudo tee $VPP_RUN_DIR/vpp.conf > /dev/null
}

azure_configure_vpp ()
{
  sudo pkill vpp || true
  sudo modprobe -a ib_uverbs
  sudo modprobe mlx4_ib
  sudo sysctl -w vm.nr_hugepages=1024

  # azure_configure_linux_router $1 # Slow path for now
  sudo ip addr flush dev $ROUTER_VM1_IF
  sudo ip addr flush dev $ROUTER_VM2_IF
  sudo sysctl net.ipv4.ip_forward=0

  azure_create_vpp_startup_conf

  echo "
    set int state $ROUTER_VM1_IF_NAME up
    set int state $ROUTER_VM2_IF_NAME up
  " | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  if [[ "$1" = "1" ]] ; then
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER_VM1_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER_VM2_BASE_IP/24

      set ip neighbor $ROUTER_VM1_IF_NAME $VM1_BASE_IP ${AZURE_RT_MAC//[$'\r']}
      set ip neighbor $ROUTER_VM2_IF_NAME $ROUTER2_VM1_BASE_IP ${AZURE_RT_MAC//[$'\r']}

      ip route add $VM1_IP_PREFIX via $VM1_BASE_IP $ROUTER_VM1_IF_NAME
      ip route add $VM2_IP_PREFIX via $ROUTER2_VM1_BASE_IP $ROUTER_VM2_IF_NAME
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  elif [[ "$1" = "2" ]] ; then
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER2_VM1_BASE_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER2_VM2_IP/24

      set ip neighbor $ROUTER_VM1_IF_NAME $ROUTER_VM2_BASE_IP ${AZURE_RT_MAC//[$'\r']}
      set ip neighbor $ROUTER_VM2_IF_NAME $VM2_BASE_IP ${AZURE_RT_MAC//[$'\r']}

      ip route add $VM1_IP_PREFIX via $ROUTER_VM2_BASE_IP $ROUTER_VM1_IF_NAME
      ip route add $VM2_IP_PREFIX via $VM2_BASE_IP $ROUTER_VM2_IF_NAME
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  else
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER_VM1_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER_VM2_BASE_IP/24
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    for ((i = 0; i < $IP_CNT; i++)); do
      echo "
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM1_IP_IT[$i]} ${AZURE_RT_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM2_IF_NAME ${VM2_IP2_IT[$i]} ${AZURE_RT_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    done
  fi

  run_vpp
}

azure_configure_ipsec ()
{
  sudo pkill vpp || true
  sudo modprobe -a ib_uverbs
  sudo modprobe mlx4_ib
  sudo sysctl -w vm.nr_hugepages=1024

  # azure_configure_linux_router $1 # Slow path for now
  sudo ip addr flush dev $ROUTER_VM1_IF
  sudo ip addr flush dev $ROUTER_VM2_IF
  sudo sysctl net.ipv4.ip_forward=0

  azure_create_vpp_startup_conf

echo "
    set int st $ROUTER_VM1_IF_NAME up
    set int st $ROUTER_VM2_IF_NAME up
  " | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  if [[ "$1" = "1" ]] ; then
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER_VM1_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER_VM2_BASE_IP/24

      ip route add $VM1_IP_PREFIX via $VM1_BASE_IP $ROUTER_VM1_IF_NAME
      set ip neighbor $ROUTER_VM1_IF_NAME $VM1_BASE_IP ${AZURE_RT_MAC//[$'\r']}
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null

    for ((i = 0; i < $IP_CNT; i++)); do
      echo "
	create ipip tunnel src ${ROUTER_VM2_IP_IT[$i]} dst ${ROUTER2_VM1_IP_IT[$i]}

	ipsec sa add 2$i spi 20$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG udp-encap tunnel-src ${ROUTER2_VM1_IP_IT[$i]} tunnel-dst ${ROUTER_VM2_IP_IT[$i]}
	ipsec sa add 3$i spi 30$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG udp-encap tunnel-src ${ROUTER_VM2_IP_IT[$i]} tunnel-dst ${ROUTER2_VM1_IP_IT[$i]}
	ipsec tunnel protect ipip$i sa-in 2$i sa-out 3$i

	set int state ipip$i up
	set int ip addr ipip$i 127.0.0.$((i+1))/32

	ip route add ${VM2_IP_IT[$i]}/32 via ipip$i
	set int ip addr $ROUTER_VM2_IF_NAME ${ROUTER_VM2_IP_IT[$i]}/24

	set ip neighbor $ROUTER_VM1_IF_NAME ${VM1_IP_IT[$i]} ${AZURE_RT_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM2_IF_NAME ${ROUTER2_VM1_IP_IT[$i]} ${AZURE_RT_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    done


  elif [[ "$1" = "2" ]] ; then
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER2_VM1_BASE_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER2_VM2_IP/24

      ip route add $VM2_IP_PREFIX via $VM2_BASE_IP $ROUTER_VM2_IF_NAME
      set ip neighbor $ROUTER2_VM2_IF_NAME $VM2_BASE_IP ${AZURE_RT_MAC//[$'\r']}
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null

    for ((i = 0; i < $IP_CNT; i++)); do
      echo "
	create ipip tunnel src ${ROUTER2_VM1_IP_IT[$i]} dst ${ROUTER_VM2_IP_IT[$i]}

	ipsec sa add 2$i spi 20$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG udp-encap tunnel-src ${ROUTER2_VM1_IP_IT[$i]} tunnel-dst ${ROUTER_VM2_IP_IT[$i]}
	ipsec sa add 3$i spi 30$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG udp-encap tunnel-src ${ROUTER_VM2_IP_IT[$i]} tunnel-dst ${ROUTER2_VM1_IP_IT[$i]}
	ipsec tunnel protect ipip$i sa-in 3$i sa-out 2$i

	set int state ipip$i up
	set int ip addr ipip$i 127.0.0.$((i+1))/32

	ip route add ${VM1_IP_IT[$i]}/32 via ipip$i
	set int ip addr $ROUTER_VM1_IF_NAME ${ROUTER2_VM1_IP_IT[$i]}/24

	set ip neighbor $ROUTER_VM2_IF_NAME ${VM2_IP_IT[$i]} ${AZURE_RT_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM1_IF_NAME ${ROUTER_VM2_IP_IT[$i]} ${AZURE_RT_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    done

  else
    echo "Missing machine #ID"
    exit 1
  fi

  run_vpp
}

aws_test_cli ()
{
  if [[ "$1" = "install" ]]; then
    azure_install_deps ${@:2}
  elif [[ "$1" = "pmd" ]]; then
    azure_configure_test_pmd ${@:2}
  elif [[ "$1" = "linux" ]]; then
    azure_configure_linux_router ${@:2}
  elif [[ "$1" = "vpp" ]]; then
    azure_configure_vpp ${@:2}
  elif [[ "$1" = "ipsec" ]]; then
    azure_configure_ipsec ${@:2}
  # VM configuration
  elif [[ "$1" = "vm1" ]]; then
    azure_configure_vm1
  elif [[ "$1" = "vm2" ]]; then
    azure_configure_vm2 $2
  else
    echo "Usage:"
    echo "aws.sh sync                                              - sync this script"
    echo "aws.sh install                                           - install deps"
    echo "aws.sh ptest [zero|one|two] [NAME] [Nparallel] [OPTIONS] - run tests"
  fi
}

aws_test_cli $@

