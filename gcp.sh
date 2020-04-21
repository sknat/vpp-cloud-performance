#!/bin/bash

MTU=${MTU:-1400}
WRK=${WRK:-1} # N workers
CP=${CP:-""} # compact workers on one thread
AES=${AES:-256} # aes-gcm-128 or aes-gcm-256
LLQ=${LLQ:-""} # 1 ti enable LLQ
PAGES=${PAGES:-1024} # symlink build directory
RXQ=${RXQ:-1}
DRIVER=${DRIVER:-""}
RXD=${RXD:-4096}
TXD=${TXD:-4096}
GSO=${GSO:-0}
BPN=${BPN:-128} # buffers per numa in K - default 64K

source $( dirname "${BASH_SOURCE[0]}" )/shared.sh

# ------------------------------

VM1_IP_IT=($(ip_it $VM1_IP $VM1_LAST_IP))
VM2_IP_IT=($(ip_it $VM2_IP $VM2_LAST_IP))
VM2_IP2_IT=($(ip_it $VM2_IP2 $VM2_LAST_IP2))
VM2_IP3_IT=($(ip_it $VM2_IP3 $VM2_LAST_IP3))
ROUTER_VM2_IP_IT=($(ip_it $ROUTER_VM2_IP $ROUTER_VM2_LAST_IP))
ROUTER2_VM1_IP_IT=($(ip_it $ROUTER2_VM1_IP $ROUTER2_VM1_LAST_IP))

IP_CNT=${#VM1_IP_IT[@]}
# IP_CNT=4

gcp_configure_test_pmd ()
{
  sudo pkill vpp || true
  sudo modprobe vfio-pci
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  sudo $DPDK_DEVBIND --force -b vfio-pci $ROUTER_VM1_IF_PCI
  sudo $DPDK_DEVBIND --force -b vfio-pci $ROUTER_VM2_IF_PCI
  sudo sysctl -w vm.nr_hugepages=$PAGES

  sudo LD_LIBRARY_PATH=$VPP_LIB_DIR $TESTPMD  \
    -w $ROUTER_VM1_IF_PCI               \
    -w $ROUTER_VM2_IF_PCI               \
    -l 0,1,2,3,4,5                            \
    --                                        \
    -i \
    --eth-peer=0,${GCP_RT_MAC//[$'\r']}     \
    --eth-peer=1,${GCP_RT_MAC//[$'\r']}     \
    -a                                        \
    --forward-mode=mac                        \
    --burst=32                                \
    --rss                                     \
    --rxq=$WRK                                \
    --txq=$WRK                                \
    --nb-cores=$WRK
}

gcp_configure_vm1 ()
{
  # OK
  sudo ip link set $VM1_IF down
  sudo ip link set $VM1_IF up
  sudo ip addr flush dev $VM1_IF

  sudo ip addr add $VM1_BASE_IP/26 dev $VM1_IF || true
  sudo arp -i $VM1_IF -s $ROUTER_VM1_IP $ROUTER_VM1_MAC
  sudo arp -i $VM1_IF -s $VM2_BASE_IP3 $VM2_IF3_MAC
  for ((i = 0; i < $IP_CNT; i++)); do
    sudo ip addr add ${VM1_IP_IT[$i]}/26 dev $VM1_IF || true
  done
  sleep 1
  sudo ip route add $VM2_IP_PREFIX via $ROUTER_VM1_IP || true
  sudo ip route add $VM2_IP2_PREFIX via $ROUTER_VM1_IP || true
  sudo ip route add $VM2_IP3_PREFIX via $VM2_BASE_IP3 || true

  sudo ip link set $VM1_IF mtu $MTU
}

gcp_configure_vm2 ()
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

  sudo ip addr add $VM2_BASE_IP/26 dev $VM2_IF || true
  sudo ip addr add $VM2_BASE_IP2/26 dev $VM2_IF2 || true
  sudo ip addr add $VM2_BASE_IP3/26 dev $VM2_IF3 || true

  sudo arp -i $VM2_IF -s $ROUTER2_VM2_IP $ROUTER2_VM2_MAC
  sudo arp -i $VM2_IF2 -s $ROUTER_VM2_BASE_IP $ROUTER_VM2_MAC
  sudo arp -i $VM2_IF3 -s $VM1_BASE_IP $VM1_MAC
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
  sudo ip link set $VM2_IF2 mtu $MTU
  sudo ip link set $VM2_IF3 mtu $MTU
}

gcp_unconfigure_all ()
{
  sudo pkill vpp || true

}

gcp_configure_linux_router ()
{
  # OK
  sudo ip link set $ROUTER_VM1_IF down
  sudo ip link set $ROUTER_VM1_IF up
  sudo ip link set $ROUTER_VM2_IF down
  sudo ip link set $ROUTER_VM2_IF up
  sudo ip addr flush dev $ROUTER_VM1_IF
  sudo ip addr flush dev $ROUTER_VM2_IF

  if [[ "$1" = "1" ]] ; then
    sudo ip addr add $ROUTER_VM1_IP/24 dev $ROUTER_VM1_IF
    sudo ip addr add $ROUTER_VM2_BASE_IP/24 dev $ROUTER_VM2_IF

    sudo ip route add $VM1_IP_PREFIX dev $ROUTER_VM1_IF via $VM1_BASE_IP || true
    sudo ip route add $VM2_IP_PREFIX dev $ROUTER_VM2_IF via $ROUTER2_VM1_BASE_IP || true

    sudo arp -i $ROUTER_VM2_IF -s $ROUTER2_VM1_BASE_IP $GCP_RT_MAC
    sudo arp -i $ROUTER_VM1_IF -s $VM1_BASE_IP $GCP_RT_MAC
  elif [[ "$1" = "2" ]] ; then
    sudo ip addr add $ROUTER2_VM1_BASE_IP/24 dev $ROUTER_VM1_IF
    sudo ip addr add $ROUTER2_VM2_IP/24 dev $ROUTER_VM2_IF

    sudo ip route add $VM1_IP_PREFIX dev $ROUTER_VM1_IF via $ROUTER_VM2_BASE_IP || true
    sudo ip route add $VM2_IP_PREFIX dev $ROUTER_VM2_IF via $VM2_BASE_IP || true

    sudo arp -i $ROUTER_VM2_IF -s $VM2_BASE_IP $GCP_RT_MAC
    sudo arp -i $ROUTER_VM1_IF -s $ROUTER_VM2_BASE_IP $GCP_RT_MAC
  else
    echo "One hop"
    sudo ip addr add $ROUTER_VM1_IP/24 dev $ROUTER_VM1_IF
    sudo ip addr add $ROUTER_VM2_BASE_IP/24 dev $ROUTER_VM2_IF

    sudo ip route add $VM1_IP_PREFIX dev $ROUTER_VM1_IF via $VM1_BASE_IP || true
    sudo ip route add $VM2_IP2_PREFIX dev $ROUTER_VM2_IF via $VM2_BASE_IP2 || true

    sudo arp -i $ROUTER_VM2_IF -s $VM2_BASE_IP2 $GCP_RT_MAC
    sudo arp -i $ROUTER_VM1_IF -s $VM1_BASE_IP $GCP_RT_MAC
  fi

  sudo sysctl net.ipv4.ip_forward=1

  sudo ip link set $ROUTER_VM1_IF mtu $MTU
  sudo ip link set $ROUTER_VM2_IF mtu $MTU
}

gcp_install_deps ()
{
  if [[ "$1" = "vm1" ]] || [[ "$1" = "vm2" ]]; then
    sudo apt update && sudo apt install -y iperf iperf3 traceroute netsniff-ng
  else
    sudo apt update && sudo apt install -y \
      iperf \
      iperf3 \
      traceroute \
      make \
      python \
      linux-tools-$(uname -r) \
      linux-tools-generic \
      libssl-dev \
      netsniff-ng \
      libmnl-dev librdmacm-dev librdmacm1 build-essential libnuma-dev # dpdk
    git clone https://gerrit.fd.io/r/vpp || true
    cd vpp
    git apply ~/test/patch/vpp-dpdk.patch
    make install-dep
    make build-release
  fi
}

gcp_create_vpp_startup_conf ()
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
    ROUTER_VM2_IF_NAME=VM2_IF
    IF_PCI2="dev $ROUTER_VM2_IF_PCI { name VM2_IF }"
  else
    ROUTER_VM2_IF_NAME=VM1_IF
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
  " | sudo tee $VPP_RUN_DIR/vpp.conf > /dev/null
  if [[ "$DRIVER" = "native" ]]; then
    echo "
      plugins {
      	plugin dpdk_plugin.so { disable }
      }
    " | sudo tee -a $VPP_RUN_DIR/vpp.conf > /dev/null
  elif [[ "$DRIVER" = "both" ]]; then
    echo "
      dpdk {
      	enable-tcp-udp-checksum
	dev default {
          num-rx-queues $RXQ
          num-rx-desc $RXD
          num-tx-desc $RXD
	}
	dev $ROUTER_VM1_IF_PCI { name VM1_IF tso on }
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
	}
	dev $ROUTER_VM1_IF_PCI { name VM1_IF tso on }
	$IF_PCI2
      }
    " | sudo tee -a $VPP_RUN_DIR/vpp.conf > /dev/null
  fi
}

gcp_configure_vpp ()
{
  sudo pkill vpp || true
  sudo modprobe vfio_pci
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  bind_to $ROUTER_VM1_IF_PCI vfio-pci
  bind_to $ROUTER_VM2_IF_PCI vfio-pci
  sudo sysctl -w vm.nr_hugepages=$PAGES

  gcp_create_vpp_startup_conf

  echo "" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null
  if [[ "$DRIVER" = "native" ]]; then
    ROUTER_VM1_IF_NAME=virtio-0/0/5/0
    ROUTER_VM2_IF_NAME=virtio-0/0/6/0
    echo "
      create interface virtio $ROUTER_VM1_IF_PCI gso-enabled
      create interface virtio $ROUTER_VM2_IF_PCI gso-enabled
      set interface feature gso $ROUTER_VM1_IF_NAME enable
      set interface feature gso $ROUTER_VM1_IF_NAME enable
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  elif [[ "$DRIVER" = "both" ]]; then
    ROUTER_VM2_IF_NAME=virtio-0/0/6/0
    echo "
      create interface virtio $ROUTER_VM2_IF_PCI gso-enabled
      set interface feature gso $ROUTER_VM1_IF_NAME enable
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  fi

  echo "
    set int state $ROUTER_VM1_IF_NAME up
    set int state $ROUTER_VM2_IF_NAME up
  " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null

  if [[ "$1" = "1" ]] ; then
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER_VM1_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER_VM2_BASE_IP/24

      set ip neighbor $ROUTER_VM1_IF_NAME $VM1_BASE_IP ${VM1_MAC//[$'\r']}
      set ip neighbor $ROUTER_VM2_IF_NAME $ROUTER2_VM1_BASE_IP ${ROUTER2_VM1_MAC//[$'\r']}

      ip route add $VM1_IP_PREFIX via $VM1_BASE_IP $ROUTER_VM1_IF_NAME
      ip route add $VM2_IP_PREFIX via $ROUTER2_VM1_BASE_IP $ROUTER_VM2_IF_NAME
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  elif [[ "$1" = "2" ]] ; then
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER2_VM1_BASE_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER2_VM2_IP/24

      set ip neighbor $ROUTER_VM1_IF_NAME $ROUTER_VM2_BASE_IP ${ROUTER_VM2_MAC//[$'\r']}
      set ip neighbor $ROUTER_VM2_IF_NAME $VM2_BASE_IP ${VM2_IF_MAC//[$'\r']}

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
	set ip neighbor $ROUTER_VM1_IF_NAME ${VM1_IP_IT[$i]} ${VM1_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM2_IF_NAME ${VM2_IP2_IT[$i]} ${VM2_IF2_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    done
  fi

  run_vpp
}

gcp_configure_ipsec ()
{
  sudo pkill vpp || true
  sudo modprobe vfio_pci
  echo 1 | sudo tee /sys/module/vfio/parameters/enable_unsafe_noiommu_mode
  bind_to $ROUTER_VM1_IF_PCI vfio-pci
  bind_to $ROUTER_VM2_IF_PCI vfio-pci
  sudo sysctl -w vm.nr_hugepages=$PAGES

  gcp_create_vpp_startup_conf

  echo "" | sudo tee $VPP_RUN_DIR/startup.conf > /dev/null
  if [[ "$DRIVER" = "native" ]]; then
    ROUTER_VM1_IF_NAME=virtio-0/0/5/0
    ROUTER_VM2_IF_NAME=virtio-0/0/6/0
    echo "
      create interface virtio $ROUTER_VM1_IF_PCI gso-enabled
      create interface virtio $ROUTER_VM2_IF_PCI gso-enabled
      set interface feature gso $ROUTER_VM1_IF_NAME enable
      set interface feature gso $ROUTER_VM2_IF_NAME enable
      set int st $ROUTER_VM1_IF_NAME up
      set int st $ROUTER_VM2_IF_NAME up
    " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
  fi

  echo "
    set int st $ROUTER_VM1_IF_NAME up
    set int st $ROUTER_VM2_IF_NAME up
  " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null

  if [[ "$1" = "1" ]] ; then
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER_VM1_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER_VM2_BASE_IP/24

      ip route add $VM1_IP_PREFIX via $VM1_BASE_IP $ROUTER_VM1_IF_NAME
      set ip neighbor $ROUTER_VM1_IF_NAME $VM1_BASE_IP ${GCP_RT_MAC//[$'\r']}
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

	set ip neighbor $ROUTER_VM1_IF_NAME ${VM1_IP_IT[$i]} ${GCP_RT_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM2_IF_NAME ${ROUTER2_VM1_IP_IT[$i]} ${GCP_RT_MAC//[$'\r']}
      " | sudo tee -a $VPP_RUN_DIR/startup.conf > /dev/null
    done


  elif [[ "$1" = "2" ]] ; then
    echo "
      set int ip addr $ROUTER_VM1_IF_NAME $ROUTER2_VM1_BASE_IP/24
      set int ip addr $ROUTER_VM2_IF_NAME $ROUTER2_VM2_IP/24

      ip route add $VM2_IP_PREFIX via $VM2_BASE_IP $ROUTER_VM2_IF_NAME
      set ip neighbor $ROUTER_VM2_IF_NAME $VM2_BASE_IP ${GCP_RT_MAC//[$'\r']}
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

	set ip neighbor $ROUTER_VM2_IF_NAME ${VM2_IP_IT[$i]} ${GCP_RT_MAC//[$'\r']}
	set ip neighbor $ROUTER_VM1_IF_NAME ${ROUTER_VM2_IP_IT[$i]} ${GCP_RT_MAC//[$'\r']}
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
    gcp_install_deps ${@:2}
  elif [[ "$1" = "pmd" ]]; then
    gcp_configure_test_pmd ${@:2}
  elif [[ "$1" = "linux" ]]; then
    gcp_configure_linux_router ${@:2}
  elif [[ "$1" = "vpp" ]]; then
    gcp_configure_vpp ${@:2}
  elif [[ "$1" = "ipsec" ]]; then
    gcp_configure_ipsec ${@:2}
  # VM configuration
  elif [[ "$1" = "vm1" ]]; then
    gcp_configure_vm1
  elif [[ "$1" = "vm2" ]]; then
    gcp_configure_vm2 $2
  else
    echo "Usage:"
    echo "aws.sh sync                                              - sync this script"
    echo "aws.sh install                                           - install deps"
    echo "aws.sh ptest [zero|one|two] [NAME] [Nparallel] [OPTIONS] - run tests"
  fi
}

aws_test_cli $@

