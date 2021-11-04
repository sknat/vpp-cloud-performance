#!/bin/bash

# This scripts uses the aws cli and gnuplot to do a daily billing recap of
# aws's billing as a webex bot
#
# Dependancies :
# this depends on jq, gnuplot & aws being installed
# and aws credentials being setup (usually in ~/.aws/credentials)
#
# To use it, go to the following link to create a webex bot
# https://developer.webex.com/docs/bots
#
# You should define in ./conf/crendentials the following variables :
# WEBEX_ACCESS_TOKEN=<Some Room Id>
#
# Then, add the bot to the room you want and run
# `webex_pricing_watcher.sh list` this will give you the list of
# room IDs the bot has access to. You can choose the right one
# and export
# WEBEX_ROOM_ID=<Some Room Id>

# Generating the report can be done simply running `webex_pricing_watcher.sh report`

SCRIPTDIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
JQ_BIN=jq
AWS_BIN=aws
GNUPLOT_BIN=gnuplot
DATE_BIN=date

if [ -e $SCRIPTDIR/conf/credentials ]; then
    source $SCRIPTDIR/conf/credentials
fi

monday () { $DATE_BIN -d"monday-$((($1 + 1) * 7))days" "+%Y-%m-%d" ; } # $1 weeks ago get the monday
sunday () { $DATE_BIN -d"sunday-$(($1 * 7))days" "+%Y-%m-%d" ; }       # $1 weeks ago get the sunday
som () { $DATE_BIN -d "-$1 month" "+%Y-%m-01";  }                      # $1 month ago, START of month
eom () { $DATE_BIN -d "$(som $1)+ 1 month - 1 day" "+%Y-%m-%d" ; }     # $1 month ago, END of month

get_aws_cost ()
{
  start=$($DATE_BIN -d "-4 month" "+%Y-%m-01")
  end=$($DATE_BIN "+%Y-%m-%d")

  echo "Get data $start -> $end ..."
  $AWS_BIN ce get-cost-and-usage \
      --time-period Start=${start},End=${end} \
      --granularity DAILY \
      --metric BlendedCost > /tmp/aws-pricing.json

  echo "Call jq..."
  echo 'BEGIN {
    m=int((n+1)/2)
}
{L[NR]=$2; sum+=$2}
NR>=m {d[++i]=$1}
NR>n {sum-=L[NR-n]}
NR>=n{
    a[++k]=sum/n
}
END {
    for (j=1; j<=k; j++)
        print d[j],a[j]
}' > /tmp/moving_avg.awk
  cat /tmp/aws-pricing.json \
    | $JQ_BIN -r '.ResultsByTime[] | .TimePeriod.Start + " " + .Total.BlendedCost.Amount' \
    | awk -vn=5 -f /tmp/moving_avg.awk \
    | tail -n 90 > /tmp/out.txt

  echo "plot..."
  $GNUPLOT_BIN -e "set terminal png;
  set xdata time;
  set timefmt '%Y-%m-%d';
  set format x '%d/%m/%Y';
  set autoscale y;
  set title 'Pricing AWS - last 90 days';
  set ylabel 'USD';
  set xlabel 'Day';
  set autoscale xfix;
  set style data lines;
  set grid;
  plot '/tmp/out.txt' using 1:2 title '7 day moving average'" > /tmp/graph.png

}

get_azure_cost ()
{
  az consumption usage list -s 2020-02-01 -e $($DATE_BIN "+%Y-%m-%d") | \
    jq -r .[].pretaxCost | \
    awk '{sum+=$1;} END{print sum;}'
}

list_rooms () {
    curl --header "Authorization: Bearer $WEBEX_ACCESS_TOKEN" \
     "https://api.ciscospark.com/v1/rooms" | \
     $JQ_BIN
}

cleanup ()
{
  rm /tmp/out.txt
  rm /tmp/graph.png
  rm /tmp/aws-pricing.json
  rm /tmp/moving_avg.awk
}

get_message () {
    WEEK_0=$(cat /tmp/out.txt|tail -n7 |head -n7|awk '{sum+=$2;} END{print sum;}')
    WEEK_1=$(cat /tmp/out.txt|tail -n14|head -n7|awk '{sum+=$2;} END{print sum;}')
    WEEK_2=$(cat /tmp/out.txt|tail -n21|head -n7|awk '{sum+=$2;} END{print sum;}')
    MONTH_0=$(cat /tmp/out.txt|tail -n31|head -n31|awk '{sum+=$2;} END{print sum;}')
    MONTH_1=$(cat /tmp/out.txt|tail -n62|head -n31|awk '{sum+=$2;} END{print sum;}')
    MONTH_2=$(cat /tmp/out.txt|tail -n93|head -n31|awk '{sum+=$2;} END{print sum;}')
    printf "AWS costs report $($DATE_BIN)\\n"
    printf "\\n"
    printf "            : this     previous   (-2)  \\n"
    printf "    weekly  : %-8s %-8s %-8s\\n" $WEEK_0 $WEEK_1 $WEEK_2
    printf "    monthly : %-8s %-8s %-8s\\n" $MONTH_0 $MONTH_1 $MONTH_2
    printf "\\n"
    printf "Check things at https://console.aws.amazon.com/cost-management/home#/dashboard\\n"
}

post_message () {
    MESSAGE="$(get_message)"
    curl --request POST \
      --header "Authorization: Bearer $WEBEX_ACCESS_TOKEN" \
      --form "roomId=${WEBEX_ROOM_ID}" \
      --form "markdown=${MESSAGE}" \
      --form "files=@/tmp/graph.png;type=image/png" \
      "https://webexapis.com/v1/messages"
}

if [  "$1" = "report" ]; then
    if [ -z ${WEBEX_ACCESS_TOKEN+x} ] || [ -x ${WEBEX_ROOM_ID+x} ]; then
	echo "Missing WEBEX_ACCESS_TOKEN or WEBEX_ROOM_ID"
	exit 1
    fi
    get_aws_cost && post_message && cleanup
elif [  "$1" = "list" ]; then
    if [ -z ${WEBEX_ACCESS_TOKEN+x} ]; then
	echo "Missing WEBEX_ACCESS_TOKEN"
	exit 1
    fi
    list_rooms
else
    echo "webex_pricing_watcher.sh list      -- list rooms for the current bot"
    echo "webex_pricing_watcher.sh report    -- post the report to webex"
fi