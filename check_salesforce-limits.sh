#!/bin/bash
#
# BSD Licensed (http://opensource.org/licenses/BSD-2-Clause):
#
# Copyright (c) 2019, ICIX, LLC
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification, are
# permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of
# conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of
# conditions and the following disclaimer in the documentation and/or other materials
# provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
# THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
# TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

PROGNAME=`basename $0`
VERSION="0.1"
AUTHOR="Jeff Vier <jeff@jeffvier.com> / https://github.com/boinger"

DEBUG=0
user='user.name@org.xxx'  ## set this if you only have one Org.
tempfilemaxage=30 ## in minutes
perfdata=false

## Initial vars
STATELEVEL=3  ## Initial statelevel

Desc="$PROGNAME is a Nagios plugin to retrieve and evaluate Org data from Salesforce."

Usage="Basic Usage:\n
    $PROGNAME -u $user -t

    Options:
      -l <target limit>|--limit=<target limit>
         What limit are we checking on? Example: DataStorageMB
         Hint: run \`sudo sfdx force:limits:api:display -u <username>\` to see the full list.
      -u <username> |--user=<username>)
         Defines the username to use to connect, which in turn defines what Org is queried. Default: $user

      -w <warning threshold>|--warning=<warning threshold>
         May be expressed in hard numbers or percentage.  Percentage is strongly recommended. Optional.
      -c <critical threshold>|--critical=<critical threshold>
         May be expressed in hard numbers or percentage.  Percentage is strongly recommended. Technically optional.

      -t <filename>|--tempfile=<filename>)
         Store results in (and references results from) a temp file.  Saves on API calls if you're watching a bunch of different limits. Optional. Recommended: /dev/shm/$PROGNAME.tempfile
      --tempfilemaxage=<minutes>)
         Max age of the tempfile, if used, in minutes.  Default: $tempfilemaxage

      -v)
          Verbose.  Add more (-vvv or -v -v -v) for even more verbosity.
      --debug)
          Max verbosity (same as -vvvvv)

      -h|--help)
          You're looking at it.
      -V|--version)
          Just version info
"
print_version() {
  echo -e "$PROGNAME v$VERSION"
  exit 3
}
print_help() {
  echo -e "$PROGNAME v$VERSION\nAuthor: $AUTHOR"
  echo -e "\n$Desc\n\n$Usage"
  exit 3
}
# options may be followed by one colon to indicate they have a required argument
if ! options=$(getopt -a -o c:hl:t:u:vVw: -l critical:,debug,help,limit:,tempfile:,tempfilemaxage:,user:,version,warning: -- "$@"); then exit 1; fi

eval set -- $options

while [ $# -gt 0 ]; do
    case "$1" in
      --debug)         DEBUG=5 ;;
      -h|--help)       print_help; exit 3 ;;
      -V|--version)    print_version $PROGNAME $VERSION; exit 3 ;;
      -v)              let DEBUG=$DEBUG+1 ;;
      -u|--user)       user=$2 ; shift;;
      -l|--limit)      limit=$2 ; shift;;
      -t|--tempfile)   tempfile=$2 ; shift;;
      --tempfilemaxage)tempfilemaxage=$2 ; shift;;
      -w|--warning)    warn=$2 ; shift;;
      -c|--critical)   crit=$2 ; shift;;
      (--) shift; break;;
      (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 99;;
      (*) break;;
    esac
    shift
done

if [ -z "$limit" ]; then
  echo "You need to set a --limit.  Cannot continue."
  print_help
  exit 3
fi


[ $DEBUG -ge 5 ] && DEBUG=5

[ $DEBUG -ge 1 ] && echo "[DEBUG1] Verbosity level $DEBUG"

[ -z $warn ] && warn=$crit && [ $DEBUG -ge 4 ] && echo "[DEBUG4] --warn missing.  set to --crit (${crit}) for simplicity."

if [ "${crit:(-1)}" == "%" ] || [ "${warn:(-1)}" == "%" ] && [ ${crit:(-1)} != ${warn:(-1)} ]; then
  echo "ERROR - Please don't mix percentage and hard number thresholds.  Fix this and re-run."
  exit 97
fi


get_status() {
  if [[ -n "$tempfile" ]]; then
    [ $DEBUG -ge 2 ] && echo "[DEBUG2] \$tempfile is set to ${tempfile}"
    tempfileage=$(date +%s -r $tempfile)
    [ $DEBUG -ge 4 ] && echo "[DEBUG4] \$tempfile age is ${tempfileage}"
    [ $DEBUG -ge 4 ] && echo "[DEBUG4] \$tempfile maxage in epoch format is $(date +%s --date="$tempfilemaxage min ago"), a delta of $((${tempfileage} - $(date +%s --date="$tempfilemaxage min ago"))) vs max of $((60*${tempfilemaxage}))"
  fi

  if [[ -r $tempfile && $tempfileage -ge $(date +%s --date="$tempfilemaxage min ago") ]]; then
    [ $DEBUG -ge 3 ] && echo "[DEBUG3] Tempfile exists and is younger than $tempfilemaxage minutes.  Using that."
    output=$(cat $tempfile)
  else
    cmd="sudo sfdx force:limits:api:display -u $user"
    [ $DEBUG -ge 3 ] && echo "[DEBUG3] Executing: ${cmd}"
    output=$($cmd)
    if [ -n "$tempfile" ]; then
      if [[ ! -w $tempfile || $tempfileage -lt $(date +%s --date="$tempfilemaxage min ago") ]]; then
        [ $DEBUG -ge 1 ] && echo "[DEBUG1] Writing output to ${tempfile}"
        echo "${output}" >> $tempfile
      fi
    fi
  fi
  [ $DEBUG -ge 5 ] && echo -e "[DEBUG5] Limits output:\n${output}"
}

get_val() {
  [ $DEBUG -ge 2 ] && echo -e "[DEBUG2] pulling $1 from \$output"
  IFS=' '
  read -a limarr <<< $(grep $1 <<< $output)
}

set_state() { ## pass in numeric statelevel
  if [ $1 -gt $STATELEVEL ] || [ $STATELEVEL -eq 3 ]; then
    STATELEVEL=$1
    case "$STATELEVEL" in
      3) STATE="UNKNOWN" ;;
      2) STATE="CRITICAL" ;;
      1) STATE="WARNING" ;;
      0) STATE="OK" ;;
    esac
  fi
}

do_output() {
  echo -e "Everything seems fine?"
}

eval_lt() {
  WHAT=$1 ## What are we checking?
  WTH=$2 ## Warning threshold (integer)
  CTH=$3 ## Crit threshold (integer)
  VAL=$4 ## Value being evaluated (integer)
  [ $DEBUG -ge 5 ] && echo "[DEBUG5] WHAT: $WHAT WTH: $WTH CTH: $CTH VAL: $VAL"
  if [ "${crit:(-1)}" == "%" ]; then
    exitval="${VAL}%"
  else
    exitval=$VAL
  fi
  if [ $WTH -lt $CTH ]; then
    echo "ERROR - you can't have a Warning threshold less than a Critical threshold when we're comparing for minimums.  Fix it."
    exit 98
  fi
  [ $DEBUG -ge 1 ] && echo "[DEBUG1] $WHAT is being checked"
  if [ $VAL -le $CTH ]; then
    [ $DEBUG -ge 2 ] && echo "[DEBUG2] $VAL < $CTH! Critical!"
    set_state 2
    EXITMESSAGE="$WHAT is CRITICAL ($exitval with crit of $crit)"
  elif [ $VAL -le $WTH ]; then
    [ $DEBUG -ge 2 ] && echo "[DEBUG2] $VAL < $WTH! Warning!"
    set_state 1
    EXITMESSAGE="$WHAT is WARNING ($exitval with warn of $warn)"
  else
    EXITMESSAGE="$WHAT is OK ($exitval with crit of $crit)"
  fi
}

# Here we go!
get_status

if [ -z "$output" ]; then
  echo "UNKNOWN - No status content retrieved (Could not connect with user $user, probably)"
  exit 3
else
  get_val $limit

  if [ -z "$limarr" ]; then
    echo "UNKNOWN - Error parsing limit output"
    exit 3
  elif [ -z "$crit" ]; then
    set_state 0
    echo -n "$STATE - ${limarr[0]}: ${limarr[1]}/${limarr[2]}"
    exit 0
  else
    set_state 0 ##assume we're ok
    if [ "${crit:(-1)}" == "%" ]; then
      [ $DEBUG -ge 4 ] && echo "[DEBUG4] --crit is set to $crit, so we're using percentage logic"
      value=$(echo "scale=2; ${limarr[1]}/${limarr[2]}*100" | bc)
      value=${value%.*}
      critval=${crit%\%*}
      warnval=${warn%\%*}
    else
      [ $DEBUG -ge 4 ] && echo "[DEBUG4] --crit is set to $crit, so we're using basic comparison logic"
      value=${limarr[1]}
      critval=${crit} ## keeping consistent to above
      warnval=${warn}
    fi
    [ $DEBUG -ge 2 ] && echo "[DEBUG2] Value being evaluated is $value"
    #eval_lt "Descriptive name" $warn $crit $value
    eval_lt "${limarr[0]}" $warnval $critval $value
    ##[ $DEBUG -ge 1 ] && echo -n "[DEBUG3] " && do_output
  fi
fi

echo -n "$STATE - $EXITMESSAGE"
[ $perfdata == true ] && echo " | 'a'=$a 'b'=$b 'zz'=$zzz" || echo
exit $STATELEVEL
