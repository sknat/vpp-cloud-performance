#!/bin/bash

function get_ethtool ()
{
  ethtool -S $NIC | grep -e ${RX}'_queue_[0-9]*_'${BYTES} | cut -d ':' -f 2 | sed 's/ //g'
}

print_usage_and_exit ()
{
  echo "Usage:"
  echo "qpps.sh eth0 [rx|tx] [packets|bytes] [-i N]"
  exit 0
}

function clear_exit ()
{
  clear
  exit
}


function main ()
{
  RX=rx
  BYTES=bytes
  INTERVAL=1
  while (( "$#" )) ; do
      case "$1" in
          rx)
              RX=rx
              ;;
          tx)
              RX=tx
              ;;
          bytes)
              BYTES=bytes
              ;;
          packets)
              BYTES=packets
              ;;
          -i)
	      shift
	      INTERVAL=$1
	      ;;
          --help)
              print_usage_and_exit
              ;;
          *)
	      NIC=$1
              ;;
      esac
      shift
  done

  if [[ "$NIC" = "" ]]; then
    print_usage_and_exit
  fi
  if [[ "$INTERVAL" = "" ]]; then
    print_usage_and_exit
  fi

  clear
  trap clear_exit 2
  IFSTATS=()
  for x in $(get_ethtool); do
    IFSTATS+=($x)
  done

  while true; do
    printf "\033[0;0f"
    echo "-------$RX on $NIC-------"
    sleep $INTERVAL
    _IFSTATS=()
    local i=0
    for x in $(get_ethtool); do
      _IFSTATS+=($x)
      echo "${RX}_queue_${i}_${BYTES}: "$(( $x - ${IFSTATS[$i]} ))"                       "
      i=$((i + 1))
    done
    echo "-------------------------"
    IFSTATS=(${_IFSTATS[@]})
  done

}

main $@

