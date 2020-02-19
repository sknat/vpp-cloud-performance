#!/bin/bash

source $( dirname "${BASH_SOURCE[0]}" )/shared.sh

configure_vms ()
{
  local _conf
  if [[ "$CONF" = "zero" ]]; then
    _conf=zero
  elif [[ "$CONF" = "linux" ]]; then
    _conf=one
  elif [[ "$CONF" = "pmd" ]]; then
    _conf=one
  elif [[ "$CONF" = "vpp" ]]; then
    _conf=one
  elif [[ "$CONF" = "linux-linux" ]]; then
    _conf=two
  elif [[ "$CONF" = "pmd-pmd" ]]; then
    _conf=two
  elif [[ "$CONF" = "vpp-vpp" ]]; then
    _conf=two
  elif [[ "$CONF" = "ipsec" ]]; then
    _conf=two
  else
    echo "Wrong configuration : $CONF"
    exit 1
  fi
  MTU=$MTU $TARGET vm2 $_conf
  run_ $VM1_MANAGEMENT_IP "MTU=$MTU $TARGET vm1 $_conf"
}

run_switch_ ()
{
  run_ $1 "WRK=$WRK AES=$AES RXQ=$RXQ RXD=$RXD TXD=$TXD DRIVER=$DRIVER BUILD=$BUILD PAGES=$PAGES $TARGET ${@:2}"
}

run_switch1 ()
{
  mkdir -p ~/currentrun/$name
  run_switch_ $ROUTER_MANAGEMENT_IP "${@}" > /tmp/vpp-startup-sw1.log 2>&1
}

run_switch2 ()
{
  run_switch_ $ROUTER2_MANAGEMENT_IP "${@}" > /tmp/vpp-startup-sw2.log 2>&1
}

move_startup_logs ()
{
  local name=$(get_test_name)
  mv /tmp/vpp-startup-sw1.log ~/currentrun/$name/startup-sw1.log
  mv /tmp/vpp-startup-sw2.log ~/currentrun/$name/startup-sw2.log
}

configure_switches () # WRK
{
  if [[ "$CONF" = "zero" ]]; then
    echo "zero conf"
  elif [[ "$CONF" = "linux" ]]; then
    run_switch1 "linux"
  elif [[ "$CONF" = "pmd" ]]; then
    run_switch1 "pmd"
  elif [[ "$CONF" = "vpp" ]]; then
    run_switch1 "vpp"
  elif [[ "$CONF" = "linux-linux" ]]; then
    run_switch1 "linux 1"
    run_switch2 "linux 2"
  elif [[ "$CONF" = "pmd-pmd" ]]; then
    run_switch1 "pmd"
    run_switch1 "pmd"
  elif [[ "$CONF" = "vpp-vpp" ]]; then
    run_switch1 "vpp 1"
    run_switch2 "vpp 2"
  elif [[ "$CONF" = "ipsec" ]]; then
    run_switch1 "ipsec 1"
    run_switch2 "ipsec 2"
  else
    echo "Wrong configuration : $CONF"
    exit 1
  fi
}

test_multi_flows () # MTU, FORKS, FLOWS, CONF=zero|linux|vpp|pmd|linux-linux|vpp-vpp|ipsec, NAME
{
  echo "Conguring test $MACHINE/$CONF$AES.${WRK}w.mtu$MTU"
  configure_vms
  configure_switches
  ./test/test.sh ptest $(get_test_name) || true
  move_startup_logs
}

get_test_name ()
{
  echo $MACHINE/$CONF$AES$BUILD$DRIVER.${WRK}w.mtu$MTU.${FORKS}tP$FLOWS
}

TARGET=./test/gcp.sh

# MACHINE=m6g.medium CONF=vpp-vpp MTU=1500 FORKS=1  FLOWS=1  BUILD=arm WRK=0 RXQ=8 PAGES=512 test_multi_flows
# MACHINE=m6g.medium CONF=ipsec MTU=1500 FORKS=1  FLOWS=1 AES=256 BUILD=arm WRK=0 RXQ=8 PAGES=512 test_multi_flows

MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=1  FLOWS=1  AES=256 WRK=1 RXQ=2 test_multi_flows
MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=1  FLOWS=16 AES=256 WRK=1 RXQ=2 test_multi_flows
MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=16 FLOWS=16 AES=256 WRK=1 RXQ=2 test_multi_flows
MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=32 FLOWS=1  AES=256 WRK=1 RXQ=2 test_multi_flows
MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=32 FLOWS=16 AES=256 WRK=1 RXQ=2 test_multi_flows

MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=1  FLOWS=1  AES=256 WRK=1 RXQ=2 DRIVER=native test_multi_flows
MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=1  FLOWS=16 AES=256 WRK=1 RXQ=2 DRIVER=native test_multi_flows
MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=16 FLOWS=16 AES=256 WRK=1 RXQ=2 DRIVER=native test_multi_flows
MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=32 FLOWS=1  AES=256 WRK=1 RXQ=2 DRIVER=native test_multi_flows
MACHINE=n1std16 CONF=ipsec MTU=1400 FORKS=32 FLOWS=16 AES=256 WRK=1 RXQ=2 DRIVER=native test_multi_flows
















