#!/bin/bash

source $( dirname "${BASH_SOURCE[0]}" )/shared.sh

ONE_RUN_LOGFILE=/tmp/vpp-orch-one.log
RUN_LOGFILE=/tmp/vpp-orch.log
SW1_STARTUP_TMPFILE=/tmp/vpp-startup-sw1.log
SW2_STARTUP_TMPFILE=/tmp/vpp-startup-sw2.log
ORCH_CONF_FILE=$( dirname "${BASH_SOURCE[0]}" )/conf/orch

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
  run_switch_ $ROUTER_MANAGEMENT_IP "${@}" > $SW1_STARTUP_TMPFILE 2>&1
}

run_switch2 ()
{
  run_switch_ $ROUTER2_MANAGEMENT_IP "${@}" > $SW2_STARTUP_TMPFILE 2>&1
}

move_startup_logs ()
{
  local name=$(get_test_name)
  mv $SW1_STARTUP_TMPFILE ~/currentrun/$name/startup-sw1.log
  mv $SW2_STARTUP_TMPFILE ~/currentrun/$name/startup-sw2.log
}

configure_switches () # WRK
{
  if [[ "$CONF" = "zero" ]]; then
    >&2 echo "No conf"
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

append_test_results ()
{
  local bps=$(tail -n1 $ONE_RUN_LOGFILE)
  local vpp=master
  echo "$MTU;$MACHINE;$FORKS;$FLOWS;$CONF;$WRK;$AES;$vpp;$DRIVER;;;$bps" >> $RUN_LOGFILE
}

test_multi_flows () # MTU, FORKS, FLOWS, CONF=zero|linux|vpp|pmd|linux-linux|vpp-vpp|ipsec, NAME
{
  echo "Conguring test $MACHINE/$CONF$AES.${WRK}w.mtu$MTU"
  configure_vms
  configure_switches
  ./test/test.sh ptest $(get_test_name) > $ONE_RUN_LOGFILE || true
  append_test_results
  move_startup_logs
  cat $ONE_RUN_LOGFILE
  rm $ONE_RUN_LOGFILE
}

get_test_name ()
{
  echo $MACHINE/$CONF.${FORKS}t.P$FLOWS.${WRK}w.mtu$MTU.aes$AES.build$BUILD.driver$DRIVER
}

orch_cli ()
{
  rm -f $RUN_LOGFILE
  if [[ -f $ORCH_CONF_FILE ]]; then
    source $ORCH_CONF_FILE
  else
    echo "Add test run configuration in $ORCH_CONF_FILE"
    exit 1
  fi
  echo "Done, go check $RUN_LOGFILE"
}

orch_cli $@
