#!/bin/bash

MTU=${MTU:-1500}
WRK=${WRK:-4} # N workers
CP=${CP:-""} # compact workers on one thread
AES=${AES:-256} # aes-gcm-128 or aes-gcm-256
LLQ=${LLQ:-""} # 1 ti enable LLQ
DRIVER=${DRIVER:-"virtio"} # 'uio' or vfio-pci as default
BUILD=${BUILD:-""} # symlink build directory
PAGES=${PAGES:-1024} # symlink build directory
RXQ=${RXQ:-1}
RXD=${RXD:-4096}
TXD=${TXD:-4096}

source $( dirname "${BASH_SOURCE[0]}" )/shared.sh

# ------------------------------

VM1_IP_IT=($(ip_it $VM1_IP $VM1_LAST_IP))
VM2_IP_IT=($(ip_it $VM2_IP $VM2_LAST_IP))
ROUTER_VM2_IP_IT=($(ip_it $ROUTER_VM2_IP $ROUTER_VM2_LAST_IP))
ROUTER2_VM1_IP_IT=($(ip_it $ROUTER2_VM1_IP $ROUTER2_VM1_LAST_IP))

# IP_CNT=${#VM1_IP_IT[@]}
IP_CNT=2

ovh_configure_test_pmd ()
{
  sudo modprobe vfio-pci
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  sudo sysctl -w vm.nr_hugepages=$PAGES

  sudo $TESTPMD                         \
    -w $ROUTER_VM1_IF_PCI               \
    -l 0,1,2,3,4,5                      \
    -- -a                               \
    --forward-mode=mac                  \
    --burst=32                          \
    --eth-peer=0,${VM1_MAC//[$'\r']}    \
    --eth-peer=1,${VM2_MAC//[$'\r']}    \
    --rss                               \
    --nb-cores=4
}

ovh_add_vm1_addresses ()
{
  for ((i = 0; i < ${IP_CNT}; i++)); do
    sudo ip addr add ${VM1_IP_IT[$i]}/24 dev $VM1_IF || true
  done
  for ((i = 0; i < ${IP_CNT}; i++)); do
    sudo arp -i $VM1_IF -s ${VM2_IP_IT[$i]} ${NXT_HOP//[$'\r']}
  done
}

ovh_configure_vm1 ()
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
  ovh_add_vm1_addresses
  sudo ip link set $VM1_IF mtu $MTU
  sudo ip route add 10.0.7.0/24 dev $VM1_IF
}

ovh_configure_vm2 ()
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
    ovh_add_vm1_addresses
  fi
  sudo ip link set $VM2_IF mtu $MTU
  sudo ip route add 10.0.2.0/24 dev $VM2_IF
}

ovh_configure_linux_router ()
{
  # Cleanup
  sudo pkill vpp || true
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

ovh_install_deps ()
{
  if [[ "$1" = "vm1" ]] || [[ "$1" = "vm2" ]]; then
    sudo apt update && sudo apt install -y iperf iperf3 traceroute netsniff-ng
  else
    sudo apt update && sudo apt install -y iperf iperf3 traceroute make python linux-tools-$(uname -r) linux-tools-generic
    git clone https://gerrit.fd.io/r/vpp || true
    cd vpp
    git apply ~/test/patch/vpp-dpdk.patch
    make install-dep
    make build-release
  fi
}

ovh_symlink_build_dir ()
{
  if [[ "$BUILD" != "" ]]; then
    echo "Using build-$BUILD"
    cd $VPP_DIR/build-root
    rm -f install-vpp-native
    ln -s build-$BUILD install-vpp-native
    cd ~
  fi
}

ovh_create_vpp_startup_conf ()
{
  if [[ "$WRK" = "1" ]]; then
    CORELIST_WORKERS="corelist-workers 1"
  elif [[ "$WRK" = "0" ]]; then
    CORELIST_WORKERS="workers 0"
  else
    CORELIST_WORKERS="corelist-workers 1-$WRK"
  fi
  ROUTER_VM1_IF_NAME=VM1_IF
  if [[ "$ROUTER_VM2_IF_PCI" != "" ]]; then
    IF_PCI2="dev $ROUTER_VM2_IF_PCI { name VM2_IF }"
  else
    IF_PCI2=""
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
    buffers {
      buffers-per-numa $((BPN << 10))
      default data-size 4096
    }
    session { evt_qs_memfd_seg enable }
    socksvr { socket-name $VPP_RUN_DIR/vpp-api.sock }
    tcp { tso }
  " | sudo tee $VPP_RUN_DIR/vpp.conf > /dev/null
  if [[ "$DRIVER" = "native" ]]; then
    echo "
      plugins {
      	plugin dpdk_plugin.so { disable }
      }
    " | sudo tee -a $VPP_RUN_DIR/vpp.conf > /dev/null
  else
    echo "
      dpdk {
      	enable-tcp-udp-checksum
	dev default {
          num-rx-queues $RXQ
          num-rx-desc $RXD
          num-tx-desc $RXD
          tso on
	}
	dev $ROUTER_VM1_IF_PCI { name VM1_IF tso on }
	$IF_PCI2
      }
    " | sudo tee -a $VPP_RUN_DIR/vpp.conf > /dev/null
  fi

  echo "vcl {
    segment-size 4000000000
    rx-fifo-size 40000000
    tx-fifo-size 40000000
    app-scope-local
    app-scope-global
    api-socket-name $VPP_RUN_DIR/vpp-api.sock
  }
  " | sudo tee $VPP_RUN_DIR/vcl.conf > /dev/null
}

ovh_configure_vpp_nic_drivers ()
{
  sudo modprobe vfio-pci
  DPDK_DRIVER="vfio-pci"
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
}

ovh_configure_vpp ()
{
  sudo modprobe vfio_pci
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  bind_to $ROUTER_VM1_IF_PCI vfio-pci
  ovh_configure_vpp_nic_drivers
  ovh_create_vpp_startup_conf

  echo "" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null
  if [[ "$DRIVER" = "native" ]]; then
    ROUTER_VM1_IF_NAME=virtio-0/0/4/0
    echo "
      set loggin class virtio level debug
      create interface virtio $ROUTER_VM1_IF_PCI gso-enabled
      set interface feature gso $ROUTER_VM1_IF_NAME enable
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  fi
  echo "
    set int state $ROUTER_VM1_IF_NAME up
    set int ip address $ROUTER_VM1_IF_NAME 10.0.1.1$1/24
  " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null

  echo "
    ip route add $VM1_IP/24 via $ROUTER_VM1_IF_NAME
    ip route add $VM2_IP/24 via $ROUTER_VM1_IF_NAME
  " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  for ((i = 0; i < ${IP_CNT}; i++)); do
    if [[ "$1" = "1" ]] ; then
      echo "
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM2_IP_IT[$i]} ${ROUTER2_VM1_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    elif [[ "$1" = "2" ]] ; then
      echo "
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM1_IP_IT[$i]} ${ROUTER_VM2_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    else
      echo "
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    fi
  done

  run_vpp
}

ovh_unconfigure_all ()
{
  sudo pkill vpp || true
  # sudo ip link set $ROUTER_VM1_IF down
  # sudo ip link set $ROUTER_VM2_IF down
}

ovh_configure_vpp_ipsec ()
{
  sudo pkill vpp || true

  ovh_configure_vpp_nic_drivers
  ovh_create_vpp_startup_conf

  echo "" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null
  if [[ "$DRIVER" = "native" ]]; then
    ROUTER_VM1_IF_NAME=virtio-0/0/4/0
    echo "
      set loggin class virtio level debug
      create interface virtio $ROUTER_VM1_IF_PCI gso-enabled
      set interface feature gso $ROUTER_VM1_IF_NAME enable
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  fi
  echo "
    set int state $ROUTER_VM1_IF_NAME up
  " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null



  # ----------------- Startup CLIs -----------------

  if [[ "$1" = "1" ]] ; then
    echo "
      set int ip address $ROUTER_VM1_IF_NAME $ROUTER_VM1_IP/32
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  elif [[ "$1" = "2" ]] ; then
    echo "
      set int ip address $ROUTER_VM1_IF_NAME $ROUTER2_VM2_IP/32
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  fi

  for ((i = 0; i < ${IP_CNT}; i++)); do
    if [[ "$1" = "1" ]] ; then
      echo "
	set int ip address $ROUTER_VM1_IF_NAME ${ROUTER_VM2_IP_IT[$i]}/32
	create ipip tunnel src ${ROUTER_VM2_IP_IT[$i]} dst ${ROUTER2_VM1_IP_IT[$i]}

	ipsec sa add 2$i spi 20$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
	ipsec sa add 3$i spi 30$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
	ipsec tunnel protect ipip$i sa-in 2$i sa-out 3$i

	set int state ipip$i up
	set int ip addr ipip$i 127.0.0.$((i+1))/32
	set ip neighbor $ROUTER_VM1_IF_NAME ${ROUTER2_VM1_IP_IT[$i]} ${ROUTER2_VM1_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}

	ip route add ${VM1_IP_IT[$i]}/32 via $ROUTER_VM1_IF_NAME
	ip route add ${VM2_IP_IT[$i]}/32 via ipip$i
	ip route add ${ROUTER2_VM1_IP_IT[$i]}/32 via $ROUTER_VM1_IF_NAME
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    elif [[ "$1" = "2" ]] ; then
      echo "
	set int ip address $ROUTER_VM1_IF_NAME ${ROUTER2_VM1_IP_IT[$i]}/32
	create ipip tunnel src ${ROUTER2_VM1_IP_IT[$i]} dst ${ROUTER_VM2_IP_IT[$i]}

	ipsec sa add 2$i spi 20$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
	ipsec sa add 3$i spi 30$i crypto-key $CRYPTO_KEY crypto-alg $CRYPTO_ALG
	ipsec tunnel protect ipip$i sa-in 3$i sa-out 2$i

	set int state ipip$i up
	set int ip addr ipip$i 127.0.0.$((i+1))/32
	set ip neighbor $ROUTER_VM1_IF_NAME ${ROUTER_VM2_IP_IT[$i]} ${ROUTER_VM2_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM2_IP_IT[$i]} ${VM2_MAC//[$'\r']}

	ip route add ${VM2_IP_IT[$i]}/32 via $ROUTER_VM1_IF_NAME
	ip route add ${VM1_IP_IT[$i]}/32 via ipip$i
	ip route add ${ROUTER_VM2_IP_IT[$i]}/32 via $ROUTER_VM1_IF_NAME
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    fi
  done

  run_vpp
}

ovh_test_cli ()
{
  if [[ "$1" = "install" ]]; then
    ovh_install_deps ${@:2}
  elif [[ "$1" = "pmd" ]]; then
    ovh_symlink_build_dir
    ovh_unconfigure_all
    ovh_configure_test_pmd
  elif [[ "$1" = "linux" ]]; then
    ovh_symlink_build_dir
    ovh_configure_linux_router ${@:2}
  elif [[ "$1" = "vpp" ]]; then
    ovh_symlink_build_dir
    ovh_unconfigure_all
    ovh_configure_vpp ${@:2}
  elif [[ "$1" = "ipsec" ]]; then
    ovh_symlink_build_dir
    ovh_configure_vpp_ipsec ${@:2}
  # VM configuration
  elif [[ "$1" = "vm1" ]]; then
    ovh_configure_vm1 ${@:2}
  elif [[ "$1" = "vm2" ]]; then
    ovh_configure_vm2 ${@:2}
  elif [[ "$1" = "ldp" ]]; then
    sudo VCL_CONFIG=$VPP_RUN_DIR/vcl.conf LD_PRELOAD=$LDPRELOAD_PATH iperf3 ${@:2}
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

ovh_test_cli $@

