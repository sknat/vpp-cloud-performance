#!/bin/bash

MTU=${MTU:-1500}
WRK=${WRK:-4} # N workers
CP=${CP:-""} # compact workers on one thread
AES=${AES:-256} # aes-gcm-128 or aes-gcm-256
LLQ=${LLQ:-""} # 1 ti enable LLQ
DRIVER=${DRIVER:-""} # 'uio' or vfio-pci as default
BUILD=${BUILD:-""} # symlink build directory
PAGES=${PAGES:-1024} # symlink build directory
RXQ=${RXQ:-1}

source $( dirname "${BASH_SOURCE[0]}" )/shared.sh

# ------------------------------

VM1_IP_IT=($(ip_it $VM1_IP $VM1_LAST_IP))
VM2_IP_IT=($(ip_it $VM2_IP $VM2_LAST_IP))
ROUTER_VM2_IP_IT=($(ip_it $ROUTER_VM2_IP $ROUTER_VM2_LAST_IP))
ROUTER2_VM1_IP_IT=($(ip_it $ROUTER2_VM1_IP $ROUTER2_VM1_LAST_IP))

IP_CNT=${#VM1_IP_IT[@]}
# IP_CNT=4

aws_configure_test_pmd ()
{
  sudo modprobe vfio-pci
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  sudo $DPDK_DEVBIND --force -b vfio-pci $ROUTER_VM1_IF_PCI
  sudo $DPDK_DEVBIND --force -b vfio-pci $ROUTER_VM2_IF_PCI
  sudo sysctl -w vm.nr_hugepages=$PAGES

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

aws_add_vm1_addresses ()
{
  for ((i = 0; i < ${IP_CNT}; i++)); do
    sudo ip addr add ${VM1_IP_IT[$i]}/24 dev $VM1_IF || true
  done
  for ((i = 0; i < ${IP_CNT}; i++)); do
    sudo arp -i $VM1_IF -s ${VM2_IP_IT[$i]} ${NXT_HOP//[$'\r']}
  done
}

aws_configure_vm1 ()
{
  if [[ "$1" = "zero" ]]; then
    NXT_HOP=$VM2_MAC
  elif [[ "$1" = "one" ]]; then
    NXT_HOP=$ROUTER_VM1_MAC
  elif [[ "$1" = "two" ]]; then
    NXT_HOP=$ROUTER_VM1_MAC
  else
    echo "Use zero|one|two"
    exit 1
  fi

  sudo ip link set $VM1_IF down
  sudo ip link set $VM1_IF up
  sudo ip addr flush dev $VM1_IF
  aws_add_vm1_addresses
  sudo ip link set $VM1_IF mtu $MTU
  sudo ip route add 20.0.7.0/24 dev $VM1_IF
}

aws_configure_vm2 ()
{
  if [[ "$1" = "zero" ]]; then
    NXT_HOP=$VM1_MAC
  elif [[ "$1" = "one" ]]; then
    NXT_HOP=$ROUTER_VM2_MAC
  elif [[ "$1" = "two" ]]; then
    NXT_HOP=$ROUTER2_VM2_MAC
  elif [[ "$1" = "loop" ]]; then
    NXT_HOP=$VM1_MAC
  else
    echo "Use zero|one|two|loop"
    exit 1
  fi
  sudo ip link set $VM2_IF down
  sudo ip link set $VM2_IF up
  sudo ip addr flush dev $VM2_IF
  for ((i = 0; i < ${#VM1_IP_IT[@]}; i++)); do
    sudo ip addr add ${VM2_IP_IT[$i]}/24 dev $VM2_IF || true
  done
  for ((i = 0; i < ${#VM1_IP_IT[@]}; i++)); do
    sudo arp -i $VM2_IF -s ${VM1_IP_IT[$i]} ${NXT_HOP//[$'\r']}
  done
  if [[ "$1" = "loop" ]]; then
    NXT_HOP=$VM2_MAC
    aws_add_vm1_addresses
  fi
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

  sudo ip link set $ROUTER_VM1_IF mtu 9000 # all tests should be below 9k mtu
  sudo ip link set $ROUTER_VM2_IF mtu 9000 # all tests should be below 9k mtu

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

aws_install_deps ()
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

aws_symlink_build_dir ()
{
  if [[ "$BUILD" != "" ]]; then
    echo "Using build-$BUILD"
    cd $VPP_DIR/build-root
    rm -f install-vpp-native
    ln -s build-$BUILD install-vpp-native
    cd ~
  fi
}

aws_create_vpp_startup_conf ()
{
  if [[ "$WRK" = "1" ]]; then
    CORELIST_WORKERS="corelist-workers 1"
  elif [[ "$WRK" = "0" ]]; then
    CORELIST_WORKERS="workers 0"
  else
    CORELIST_WORKERS="corelist-workers 1-$WRK"
  fi
  ROUTER_VM1_NAME=VM1_IF
  if [[ "$ROUTER_VM2_IF_PCI" != "" ]]; then
    ROUTER_VM2_NAME=VM2_IF
    IF_PCI2="dev $ROUTER_VM2_IF_PCI { name VM2_IF }"
  else
    ROUTER_VM2_NAME=VM1_IF
    IF_PCI2=""
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
      dev default { num-rx-queues $RXQ num-rx-desc 1024 }
      uio-driver $DPDK_DRIVER
      dev $ROUTER_VM1_IF_PCI { name VM1_IF }
      $IF_PCI2
    }
    buffers {
      buffers-per-numa 65536
      default data-size 4096
    }
  " | sudo tee $VPP_RUN_DIR/vpp.conf > /dev/null
  sudo sysctl -w vm.nr_hugepages=$PAGES
}

aws_configure_vpp_nic_drivers ()
{
  if [[ "$DRIVER" = "uio" ]]; then
    sudo modprobe uio
    sudo insmod $IGB_UIO_KO wc_activate=1 || true
    DPDK_DRIVER="igb_uio"
  else
    sudo modprobe vfio-pci
    DPDK_DRIVER="vfio-pci"
  fi
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
}

aws_configure_vpp ()
{
  aws_configure_vpp_nic_drivers
  aws_create_vpp_startup_conf

  echo "
    set int state $ROUTER_VM1_NAME up
    set int state $ROUTER_VM2_NAME up
    set int ip address $ROUTER_VM1_NAME 127.0.0.1/32
    set int ip address $ROUTER_VM2_NAME 127.0.0.2/32
    ip route add $VM1_IP/24 via $ROUTER_VM1_NAME
    ip route add $VM2_IP/24 via $ROUTER_VM2_NAME
  " | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null
  for ((i = 0; i < ${IP_CNT}; i++)); do
    if [[ "$1" = "1" ]] ; then
      echo "
	set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM2_NAME ${VM2_IP_IT[$i]} ${ROUTER2_VM1_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    elif [[ "$1" = "2" ]] ; then
      echo "
	set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${ROUTER_VM2_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM2_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    else
      echo "
	set ip neighbor $ROUTER_VM1_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM2_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    fi
  done

  run_vpp
}

aws_unconfigure_all ()
{
  sudo pkill vpp || true
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI
  if [[ "$ROUTER_VM2_IF_PCI" != "" ]]; then
    sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI
  fi
  sudo ip link set $ROUTER_VM1_IF down
  sudo ip link set $ROUTER_VM2_IF down
}

aws_configure_vpp_ipsec ()
{
  sudo pkill vpp || true
  sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM1_IF_PCI
  if [[ "$ROUTER_VM2_IF_PCI" != "" ]]; then
    sudo $DPDK_DEVBIND --force -b ena $ROUTER_VM2_IF_PCI
  fi
  sudo ip link set $ROUTER_VM1_IF down
  sudo ip link set $ROUTER_VM2_IF down

  aws_configure_vpp_nic_drivers
  aws_create_vpp_startup_conf

  # ----------------- Startup CLIs -----------------
  echo "
    set int state $ROUTER_VM1_NAME up
    set int state $ROUTER_VM2_NAME up
  " | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null

  if [[ "$1" = "1" ]] ; then
    echo "
      set int ip address $ROUTER_VM1_NAME $ROUTER_VM1_IP/32
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  elif [[ "$1" = "2" ]] ; then
    echo "
      set int ip address $ROUTER_VM2_NAME $ROUTER2_VM2_IP/32
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  fi

  for ((i = 0; i < ${IP_CNT}; i++)); do
    if [[ "$1" = "1" ]] ; then
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
    elif [[ "$1" = "2" ]] ; then
      echo "
	set int ip address $ROUTER_VM1_NAME ${ROUTER2_VM1_IP_IT[$i]}/32
	create ipip tunnel src ${ROUTER2_VM1_IP_IT[$i]} dst ${ROUTER_VM2_IP_IT[$i]}

	ipsec sa add 2$i spi 20$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
	ipsec sa add 3$i spi 30$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
	ipsec tunnel protect ipip$i sa-in 3$i sa-out 2$i

	set int state ipip$i up
	set int ip addr ipip$i 127.0.0.$((i+1))/32
	set ip neighbor $ROUTER_VM1_NAME ${ROUTER_VM2_IP_IT[$i]} ${ROUTER_VM2_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM2_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}

	ip route add ${VM2_IP_IT[$i]}/32 via $ROUTER_VM2_NAME
	ip route add ${VM1_IP_IT[$i]}/32 via ipip$i
	ip route add ${ROUTER_VM2_IP_IT[$i]}/32 via $ROUTER_VM1_NAME
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    fi
  done

  run_vpp
}

aws_test_cli ()
{
  if [[ "$1" = "install" ]]; then
    aws_install_deps ${@:2}
  elif [[ "$1" = "pmd" ]]; then
    aws_symlink_build_dir
    aws_unconfigure_all
    aws_configure_test_pmd
  elif [[ "$1" = "linux" ]]; then
    aws_symlink_build_dir
    aws_configure_linux_router ${@:2}
  elif [[ "$1" = "vpp" ]]; then
    aws_symlink_build_dir
    aws_unconfigure_all
    aws_configure_vpp ${@:2}
  elif [[ "$1" = "ipsec" ]]; then
    aws_symlink_build_dir
    aws_configure_vpp_ipsec ${@:2}
  # VM configuration
  elif [[ "$1" = "vm1" ]]; then
    aws_configure_vm1 ${@:2}
  elif [[ "$1" = "vm2" ]]; then
    aws_configure_vm2 ${@:2}
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

