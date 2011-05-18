##############################################################################
# BASE ENV
##############################################################################
TOOLS=$(cd $(dirname -- $0) && pwd)
PATH=$TOOLS:/usr/local/symlinks:$PATH
export PATH TOOLS

umask 0022

if ${HTMLREPORTING:-false}
then
   V_BOLD="<B>"
   V_REVERSE="$V_BOLD"
   V_UNDERLINE="<U>"
   V_VIDOFF_BOLD="</B>"
   V_VIDOFF_REVERSE="$V_VIDOFF_REVERSE"
   V_VIDOFF_UNDERLINE="</U>"
elif [ -t 1 ]
then
   ## Set some video text attributes for use in error/warning msgs
   V_REVERSE='[7m'
   V_UNDERLINE='[4m'
   V_BOLD='[1m'
   [ -f /usr/bin/tput ] && V_BLINK=$(tput blink)
   V_VIDOFF='[m'
   V_VIDOFF_REVERSE="$V_VIDOFF"
   V_VIDOFF_BOLD="$V_VIDOFF"
   V_VIDOFF_UNDERLINE="$V_VIDOFF"
fi
export V_REVERSE V_UNDERLINE V_BOLD V_BLINK V_VIDOFF

# Set some usable highlighted keywords for functions like OkFailed().
OK="${V_BOLD}OK$V_VIDOFF_BOLD"
FAILED="${V_REVERSE}FAILED$V_VIDOFF_REVERSE"
WARNING="${V_REVERSE}WARNING$V_VIDOFF_REVERSE"
YES="${V_BOLD}YES$V_VIDOFF_BOLD"
NO="${V_REVERSE}NO$V_VIDOFF_REVERSE"

# Set REALUSER
#REALUSER=`id -nu`
#export REALUSER

# Set a PID for use throughout
PID=$$;export PID

# Save original cmd-line
ORIG_CMDLINE="$*"

# Define some functions when sourced from PROGrams
#[ -n "$PROG" ] && . stdlib.sh

# set a basic trap to capture ^C's and other unexpected exits and do the
# right thing in TrapClean().
trap TrapClean 2 3 15

##############################################################################
# Standard library of useful shell functions and GLOBALS
##############################################################################

# Define logecho() function to display to log and std out
# Args can be -n or -r or -nr or -rn ONLY.
# -r = raw output - no $PROG: prefix
# -n - no newline (just like echo -n)
logecho () {
# Dynamically set fmtlen
local lfmtlen=
let lfmtlen=80-${#PROG}
N=
raw=false
case "$1" in
     -n) N=-n
         shift
         ;;
     -r) raw=true
         shift
         ;;
-rn|-nr) N=-n;raw=true
         shift
         ;;
esac

# Allow widespread use of logecho without having to
# determine if $LOGFILE exists first.
#
# If -n is set, do not provide autoformatting or you lose the -n affect
# Use of -n should only be used on short status lines anyway.
if [ ! -f "$LOGFILE" ]
then
   if $raw
   then
      echo $N "$*"
   elif [ "$N" = -n ]
   then
      echo $N "$PROG: $*"
   else
      # To create a line continuation character
      #echo $N "$*" |fmt -$lfmtlen |sed -e "1s,^,$PROG: ,g" -e "2,\$s,^,$PROG: .,g"
      echo $N "$*" |fmt -$lfmtlen |sed "s,^,$PROG: ,g"
   fi
else
   if $raw
   then
      echo $N "$*" | tee -a $LOGFILE
   elif [ "$N" = -n ]
   then
      echo $N "$PROG: $*" | tee -a $LOGFILE
   else
      # To create a line continuation character
      #echo $N "$*" |fmt -$lfmtlen |sed -e "1s,^,$PROG: ,g" -e "2,\$s,^,$PROG: .,g" | tee -a $LOGFILE
      echo $N "$*" |fmt -$lfmtlen |sed "s,^,$PROG: ,g" | tee -a $LOGFILE
   fi
fi
}

logrun () {
# if no args, take stdin
if [ -z "$1" ]
then
   if ${VERBOSE:-true}
   then
      tee -a $LOGFILE
   else
      tee -a $LOGFILE > /dev/null 2>&1
   fi
elif [ -f "$LOGFILE" ]
then
   echo >> $LOGFILE
   echo "CMD: $*" >> $LOGFILE
   # Special case for "cd" which cannot be run through a pipe (subshell)
   if ${VERBOSE:-true} && [ "$1" != cd ]
   then
      ${*:-:} 2>&1 | tee -a $LOGFILE
      return ${PIPESTATUS[0]}
   else
      ${*:-:} >> $LOGFILE 2>&1
   fi
else
   if ${VERBOSE:-false}
   then
      $*
   else
      $* >/dev/null 2>&1
   fi
fi
}

OkFailed () {
if logrun $*
then
   logecho -r $OK
else
   logecho -r $FAILED
   return 1
fi
}

# Define process output
ProcessOutput () {
if ${VERBOSE:-true}
then
   tee -a $LOGFILE
else
   tee -a $LOGFILE > /dev/null 2>&1
fi
}

GeneratePassword () {
dd if=/dev/urandom count=1 2> /dev/null | uuencode -m - | sed -ne 2p | cut -c-8
}

#  TimeStamp  < begin | end | done > [ section ]
#+ DESCRIPTION
#+     TimeStamp begin is run at the beginning of the script to display a 
#+     'begin' marker and TimeStamp end is run at the end of the script to 
#+     display an 'end' marker.  
#+     TimeStamp will auto-scope to the current shell or you can optionally
#+     pass in a second argument as a section identifier if you wish to track
#+     multiple times within the same shell.
#+
#+     For example, if you call TimeStamp begin and end within one script and then
#+     call it again in another script (new shell), you can just use begin and end
#+     But if you want to call it twice within the same script use it like this:
#+    
TimeStamp ()
{
# Always set trace (set -x) back
#set +x
#
action=$1
section=${2:-run}
# convert / to underscore
section=${section//\//_}
# convert : to underscore
section=${section//:/_}
# convert . to underscore
section=${section//./_}

case "$action" in
begin)
   # Get time(date) for display and calc
   eval ${section}start_seconds=$(date '+%s')

   # Print BEGIN message for $PROG
   logecho "BEGIN $section on ${HOSTNAME%%.*} $(date)"
   [ "$section" = run ] && logecho -r
   ;;
end|done)
   # Check for "START" values before calcing
   if [ -z "$(eval echo \\$\"${section}start_seconds\")" ]
   then
      #display_time="EE:EE:EE - 'end' run without 'begin' in this scope or sourced script using TimeStamp"
      return 1
   else
      # Get time(date) for display and calc
      eval ${section}end_seconds=$(date '+%s')

      # process time
      start_display_time=$(eval echo \$"${section}start_seconds")
      # if start time is blank then just exit...
      [ -z "$start_display_time" ] && return 0
      end_display_time=$(eval echo \$"${section}end_seconds")
      display_time=$(expr ${end_display_time} - ${start_display_time:-0} |\
      awk '{ 
       in_seconds=$0
       days=in_seconds/86400
       remain=in_seconds%86400
       hours=remain/3600
       remain=in_seconds%3600
       minutes=remain/60
       seconds=remain%60
       printf("%dd %02d:%02d:%02d\n",days, hours, minutes, seconds)
      }')
   fi

   [ "$section" = run ] && logecho -r
   # To override logecho's 80-column limit, echo directly and pipe to logrun
   # for verbose/log handling
   echo "$PROG: DONE $section on ${HOSTNAME%%.*} $(date) ${V_BOLD}in $display_time$V_VIDOFF_BOLD" |VERBOSE=true logrun

   # NULL these local vars
   unset ${section}start_seconds ${section}end_seconds
   ;;
esac
}

TrapClean () {
# If user ^C's at read then tty is hosed, so make it sane again
stty sane
logecho -r
logecho -r
logecho "^C caught!"
Exit 1 "Exiting..."
}

CleanExit () {
  # cleanup CLEANEXIT_RM
  # Sanity check the list 
  # should we test that each arg is a absolute path?
  if echo "$CLEANEXIT_RM" |fgrep -qw /
  then
     logecho "/ found in CLEANEXIT_RM.  Skipping Cleanup..."
  else
     if [ -n "$CLEANEXIT_RM" ]
     then
        logecho "Cleaning up:$CLEANEXIT_RM"
     else
        : logecho "Cleaning up..."
     fi
     # cd somewhere relatively safe and run cleanup the $CLEANEXIT_RM stack
     # + some usual suspects...
     cd /tmp && rm -rf $CLEANEXIT_RM $TMPFILE1 $TMPFILE2 $TMPFILE3 $TMPDIR1 \
                                     $TMPDIR2  $TMPDIR3
  fi
  # display end timestamp when an existing TimeStamp begin was run
  [ -n "$runstart_seconds" ] && TimeStamp end
  exit ${1:-0}
}

# Requires 2 args
# - Exit code
# - message
Exit () {
  local etype=${1:-0}
  shift
  logecho -r
  logecho $*
  logecho -r
  CleanExit $etype
}

# these 2 kept for backward compat for now
Exit0 () {
  Exit 0 $*
}

Exit1 () {
  Exit 1 $*
}

Askyorn () {
local yorn
case "$1" in
   -y) # yes default
       shift
       logecho -n "$* ([y]/n)? "
       read yorn
       case "$yorn" in
           [nN]) return 1 ;;
              *) return 0 ;;
       esac
       ;;
    *) # no default
       case "$1" in
         -n) shift ;;
       esac
       logecho -n "$* (y/[n])? "
       read yorn
       case "$yorn" in
           [yY]) return 0 ;;
              *) return 1 ;;
       esac
       ;;
esac
}

##############################################################################
netls () {
url=${1:-"http://build/packages/kernel/experimental/autotest"}
wget -O - $url 2>&1 |sed -ne '/Parent Directory/,/^$/p' | sed 's,<[^>]*> *,,g' |sed -ne '2,$p' |sed '/^$/d'
}

Spinner () {
while true
do
echo -n "-"
sleep 1
echo -n "\\"
sleep 1
echo -n "|"
sleep 1
echo -n "/"
sleep 1
done
}

# Takes a step number and a string and prints out a section header
# If the first arg isn't a number, then it just prints the string
StepHeader () {
if [[ "$1" == [0-9]* ]]
then
   local step="STEP $1 - "
   shift
fi
local msg=$*
logecho -r
echo -n $V_BOLD
logecho "================================================================"
logecho "$step$msg"
logecho "================================================================"
echo -n $V_VIDOFF_BOLD
logecho -r
}

LogfileInit () {
local lnum=$2
# Initialize Logfile
# only set and shift(savefile) LOGFILE If none was set by calling program
if [ -z "$LOGFILE" ]
then
   LOGFILE=${1:-$(pwd)/$PROG.log}
   savefile file=$LOGFILE num=${lnum:-3} rm=yes
   echo "CMD: $PROG $ORIG_CMDLINE" >$LOGFILE
else
   echo "CMD: $PROG $ORIG_CMDLINE" >>$LOGFILE
fi
}

CanonicalizePath () {
[ -z "$1" ] && return
cd -P -- "$(dirname -- "$1")" &&
printf '%s\n' "$(pwd -P)/$(basename -- "$1")"
}

#####################################################################
# Set BUGSHELL_PASSWORD
#####################################################################
BugshellAuth () {
# XXX: Buganizer and SSO.  There's no solution yet that will allow
# password-less access to buganizer, so prompt for password each run. (awful)
# nmlorg trying to fix this: http://b/issue?id=759835
# If I ever want to encrypt this:
#encrypted_password=$(echo $buganizer_password |openssl des3 -a -k $cryptkey)
#decrypted_password=$(echo "$encrypted_password" |openssl des3 -d -a -k $cryptkey)

# Try to get a password from local machine
local ldap_password_file=/usr/local/google/$USER/.password
BUGANIZER_PASSWORD=$(cat $ldap_password_file 2>&-)

until $BUGSHELL --password $BUGANIZER_PASSWORD ls 2>&-
do
   echo
   read -s -p "$PROG: Access to Buganizer required. Enter your LDAP password: " BUGANIZER_PASSWORD
   echo
done
if [ "$(cat $ldap_password_file 2>&-)" != $BUGANIZER_PASSWORD ]
then
   if Askyorn "Store your password (600) in $ldap_password_file"
   then
      mkdir -p $(dirname $ldap_password_file)
      echo $BUGANIZER_PASSWORD > $ldap_password_file
      chmod 600 $ldap_password_file
   fi
fi
}

# Takes space separated list of elements and returns a random one
PickRandomElement () {
# array of strings
local llist=($@)
local lrange=
local lrand=$RANDOM

# set range
lrange=${#llist[*]}
# set boundaries
let "lrand %= $lrange"

#echo "Random number less than $lrange  ---  $lrand = ${llist[$lrand]}"
echo ${llist[$lrand]}
}

# It creates a temporary file to expand the environment variables
ManHelp () {
# Whatever caller is
local lprog=$0
local ltmpfile=/tmp/$PROG-manhelp.$$

# Standard usage function
if [ "x$usage" = "xyes" -o "x$1" = "x-usage" -o \
     "x$1" = "x--usage" -o "x$1" = "x-?" ]
then
   echo 'cat << EOFCAT' >$ltmpfile
   echo "Usage:" >> $ltmpfile
   sed -n '/#+ SYNOPSIS/,/^#+ DESCRIPTION/p' $lprog |\
    sed -e 's,^#+ ,,g' -e '/^DESCRIPTION/d' >> $ltmpfile
   echo "EOFCAT" >> $ltmpfile
   . $ltmpfile
   rm -f $ltmpfile
   exit 1
fi

# Standard man function
if [ "x$man" = "xyes" -o "x$1" = "x-man" -o \
     "x$1" = "x--man" -o "x$1" = "x-help" -o "x$1" = "x--help" ]
then
   echo 'cat << EOFCAT' >$ltmpfile
   grep "^#+" $lprog |cut -c4- >> $ltmpfile
   echo "EOFCAT" >> $ltmpfile
   . $ltmpfile | ${PAGER:-"less"}
   rm -f $ltmpfile
   exit 1
fi

# Standard comments function
if [ "x$comments" = "xyes" -o "x$1" = "x-comments" ]
then
   echo
   egrep "^#\-" $lprog |sed -e 's,^#- *,,g'
   rm -f $ltmpfile
   exit 1
fi
}

# parse cmdline
# Run namevalue as a separate script so it can handle quoted args --name="1 2"
. namevalue
# Run ManHelp to show usage and man pages
ManHelp $@

# Keep crostools up to date
# symlink may be setting by caller or use $0
# Try it using std git pull or repo sync
(cd $(dirname ${symlink:-$0}) && git pull -q >/dev/null 2>&1 ||\
 repo sync crostools > /dev/null 2>&1)
