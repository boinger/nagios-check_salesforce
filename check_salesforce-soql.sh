#!/usr/bin/env bash
#set -x
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
countstring=.result.totalSize
grepargs=""
perfdata=false

## Initial vars
STATELEVEL=3  ## Initial statelevel
LESS=0

Desc="$PROGNAME is a Nagios plugin to retrieve and evaluate SOQL queries from Salesforce Orgs."

Usage="Basic Usage:\n
    $PROGNAME -u $user -t

    Options:
      -u <username> |--user=<username>)
         Defines the username to use to connect, which in turn defines what Org is queried. Default: $user
      -Q <SOQL>|--query=<SOQL>
         SOQL to run against the Org.
      --nolimit
         If your SOQL (--query) doesn't include a LIMIT (preferably 'LIMIT 1'), you must specify this flag.  Note: there can be significant performance issues and unexpected behavior with a limitless query, so be sure you know what you're doing.

      -s <string>|--string=<string>
         Substring comparison. OK if the result *contains* this string, Critical if not.
      -i
         Case-insensitive string comparison
      --grepargs=\"<grep args>\"
         Any other grep arguments you want to pass in.

      -w <warning threshold>|--warning=<warning threshold>
         Integer to compare against COUNT() query.
      -c <critical threshold>|--critical=<critical threshold>
         Integer to compare against COUNT() query.
      -C <string>|--countstring=<string>
         JSON field to use for number comparison.  Uses jq syntax. Default is $countstring.
      -R <string>|--returnfield=<string>
         Field to return when counting (normally just the count is returned). Uses jq syntax. Example: '.result.records[-1].Id' for the last returned Id.
      --lt
         Designates that thresholds are evaluated for less-than. Default is greater-than.

      -v)
          Verbose.  Add more (-vvv or -v -v -v) for even more verbosity.
      --debug)
          Max verbosity (same as -vvvvv)

      -h|--help)
          You're looking at it.
      -V|--version)
          Just version info

      ** Note, ONE of -c|--critical, -s|--string is required.
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
if ! options=$(getopt -a -o C:c:hiQ:R:s:t:u:vVw: -l countstring:,critical:,debug,help,grepargs:,lt,nolimit,query:,returnfield:,string:,trunc:,user:,version,warning: --name "$0" -- "$@"); then exit 1; fi

eval set -- $options

req_ct=0 ## Required options count.  Should end up equal to exactly 1.
while [ $# -gt 0 ]; do
    case "$1" in
      --debug)         DEBUG=5 ;;
      -h|--help)       print_help; exit 3 ;;
      -V|--version)    print_version $PROGNAME $VERSION; exit 3 ;;
      -v)              let DEBUG=$DEBUG+1 ;;
      -u|--user)       user=$2 ; shift;;
      -Q|--query)      query=$2 ; shift;;
      --nolimit)       nolimit=1 ;; ## no shift for argumentless-options
      -s|--string)     string=$2 && let req_ct=$req_ct+1 ; shift;;
      -i)              grepargs="$grepargs -i" ;;
      --grepargs)      grepargs="$grepargs $2" ; shift;;
      -w|--warning)    warn=$2 ; shift;;
      -c|--critical)   crit=$2 && let req_ct=$req_ct+1 ; shift;;
      --lt)            LESS=1 ;;
      -C|--countstring)countstring=$2 ; shift;;
      -R|--returnfield)returnfield=$2 ; shift;;
      -t|--trunc)      trunclength=$2 ; shift;;
      (--) shift; break;;
      (-*) echo "$0: error - unrecognized option $1" 1>&2; exit 99;;
      (*) break;;
    esac
    shift
done

if [ -z "$query" ]; then
  echo "Fatal: You need to set a -Q|--query.  Cannot continue."
  print_help
  exit 3
elif [[ -z "$nolimit" && ! $query =~ "LIMIT " ]]; then
  echo "Fatal: Your query does not contain a limit and you have not specified --nolimit.  Cannot continue."
  print_help
  exit 3
elif [ "$req_ct" -ne "1" ]; then
  echo "Fatal: Exactly ONE of -c|--critical, -s|--string, -S|--substring is required.  Cannot continue."
  print_help
  exit 3
fi

[ $DEBUG -ge 5 ] && DEBUG=5

[ $DEBUG -ge 1 ] && echo "[DEBUG1] Verbosity level $DEBUG"

[ -z $warn ] && warn=$crit && [ $DEBUG -ge 4 ] && echo "[DEBUG4] --warn missing.  set to --crit (${crit}) for simplicity."

countval() { ## usage: countval <key>
  echo $output | jq "${1}"
}

get_status() {
  cmd="sfdx force:data:soql:query -rjson -u $user -q \"${query}\""
  [ $DEBUG -ge 3 ] && echo "[DEBUG3] Executing: ${cmd}"
  output=`eval ${cmd}`
  [ $DEBUG -ge 5 ] && echo -e "[DEBUG5] output:\n${output}"
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

searchresult() { ## usage searchresult <string>
  stringcheck=$(echo $output | jq '.result.records | del(.[].attributes)[] ' | grep -m1 $grepargs $1 | xargs)
  if [ -n "$stringcheck" ]; then
    set_state 0
    EXITMESSAGE="'$1' found in '$stringcheck'"
  else
    set_state 2
    EXITMESSAGE="String '$1' not found"
  fi
}


eval_gt() {
  WTH=$1 ## Warning threshold
  CTH=$2 ## Crit threshold
  VAL=$3 ## Value being evaluated
  [ $DEBUG -ge 5 ] && echo "[DEBUG5] WTH: $WTH CTH: $CTH VAL: $VAL"
  if [ $VAL -ge $CTH ]; then
    set_state 2
    EXITMESSAGE="$VAL returned (crit is max of $CTH)"
  elif [ $VAL -ge $WTH ]; then
    if [ $WTH -ge $CTH ]; then
      echo "ERROR - you can't have a Warning threshold greater than a Critical threshold.  Fix it or specify --less."
      exit 97
    fi
    set_state 1
    EXITMESSAGE="$VAL returned (crit is max of $WTH)"
  else
    EXITMESSAGE="$VAL returned (with crit of >$crit)"
  fi
}

eval_lt() {
  WTH=$1 ## Warning threshold (integer)
  CTH=$2 ## Crit threshold (integer)
  VAL=$3 ## Value being evaluated (integer)
  [ $DEBUG -ge 5 ] && echo "[DEBUG5] WTH: $WTH CTH: $CTH VAL: $VAL"
  if [ $WTH -lt $CTH ]; then
    echo "ERROR - you can't have a Warning threshold less than a Critical threshold when we're comparing for minimums.  Fix it or don't specify --less."
    exit 98
  fi
  if [ $VAL -lt $CTH ]; then
    [ $DEBUG -ge 2 ] && echo "[DEBUG2] $VAL < $CTH! Critical!"
    set_state 2
    EXITMESSAGE="$VAL returned (crit is min of $crit)"
  elif [ $VAL -lt $WTH ]; then
    [ $DEBUG -ge 2 ] && echo "[DEBUG2] $VAL < $WTH! Warning!"
    set_state 1
    EXITMESSAGE="$VAL returned (warn is min of $warn"
  else
    EXITMESSAGE="$VAL returned (with crit of <$crit)"
  fi
}

# Here we go!
get_status

if [ -z "$output" ]; then
  echo "UNKNOWN - No status content retrieved (Could not connect with user $user, probably)"
  exit 3
else
  if [ -n "$crit" ]; then
    set_state 0
    if [ $LESS -eq 1 ]; then
      eval_lt $warn $crit $(countval ${countstring})
    else
      eval_gt $warn $crit $(countval ${countstring})
    fi
  elif [ -n "$string" ]; then
    searchresult $string
  else
    echo "something else"
  fi
  if [ -n "$returnfield" ]; then
    [ $DEBUG -ge 2 ] && echo "[DEBUG2] \$returnfield is set to $returnfield, so trying to extract that from the output"
    RETURNSTRING=$(echo $output | jq "$returnfield")
    [ -n "${trunclength}" ] && [ "${#RETURNSTRING}" -gt "${trunclength}" ] && RETURNSTRING="$(echo $RETURNSTRING | cut -c 1-${trunclength})...(truncated)"
    [ $DEBUG -ge 5 ] && echo "[DEBUG5] \$returnfield found $RETURNSTRING"
    [ -n "$RETURNSTRING" ] && [ "$RETURNSTRING" != "null" ] && EXITMESSAGE="${EXITMESSAGE} / ${RETURNSTRING}"
  fi
fi

echo -n "$STATE - $EXITMESSAGE"
[ $perfdata == true ] && echo " | 'a'=$a 'b'=$b 'zz'=$zzz" || echo
exit $STATELEVEL
