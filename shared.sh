#!/bin/bash

if [[ -f ~/test/myconf.sh ]]; then
  source ~/test/myconf.sh
fi

set -e
if [[ "$X" != "" ]]; then set -x ; fi

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
  ssh $(whoami)@$1 -i $IDENTITY_FILE -t ${@:2}
}

run_vpp ()
{
  if [[ "$GDB" != "" ]]; then
    BIN="gdb --args $VPPDBGBIN"
  else
    BIN=$VPPBIN
  fi

  sudo ln -s $VPPCTLBIN /usr/local/bin/vppctl || true
  sudo DPDK_ENA_LLQ_ENABLE=$LLQ \
    LD_LIBRARY_PATH=$VPP_LIB_DIR \
    $BIN -c $VPP_RUN_DIR/vpp.conf
  if [[ "$CP" != "" ]]; then
    echo "compacting vpp workers"
    sleep 1
    pgrep -w vpp | (local i=0; while read thr; do sudo taskset -p -c $((i/2)) $thr; i=$((i+1)); done)
    echo "done"
  fi
  sleep 1
}

function bind_to ()
{
  local pci=$1
  local driver=$2
  if [[ $pci != "" ]]; then
    sudo $DPDK_DEVBIND --force -b vfio-pci $pci
  fi
}

VPP_DIR=$HOME/vpp
VPP_RUN_DIR=/run/vpp
DPDK_DEVBIND=$VPP_DIR/build-root/install-vpp-native/external/sbin/dpdk-devbind
TESTPMD=$VPP_DIR/build-root/install-vpp-native/external/bin/testpmd
VPPBIN=$VPP_DIR/build-root/install-vpp-native/vpp/bin/vpp
VPPDBGBIN=$VPP_DIR/build-root/install-vpp_debug-native/vpp/bin/vpp
VPPCTLBIN=$VPP_DIR/build-root/install-vpp-native/vpp/bin/vppctl
IGB_UIO_KO=$VPP_DIR/build-root/build-vpp-native/external/dpdk-19.08/x86_64-native-linuxapp-gcc/kmod/igb_uio.ko
VPP_LIB_DIR=$VPP_DIR/build-root/install-vpp-native/external/lib
LDPRELOAD_PATH=$VPP_DIR/build-root/build-vpp-native/vpp/lib/libvcl_ldpreload.so
IDENTITY_FILE=$HOME/key.pem

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
