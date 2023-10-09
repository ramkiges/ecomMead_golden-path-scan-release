#!/bin/sh
PATH=/apps/mead-tools:/usr/local/bin:/bin:/sbin:/usr/bin:/usr/sbin
JIRA_CSV=golden-path-tickets.csv
HIST_CSV=golden-path-history.csv
DATE=$(date +'%Y-%m-%d %H:%M')
REPO=git@github.wsgc.com:eCommerce-Mead/golden-path-scan.git
TMP=$(mktemp -p /tmp -d tmp.golden-path-scan.XXX)

# tickets older than this we won't bother to re-scan
[[ -z $DAYS ]] && DAYS=3

# tickets older than this we just close
[[ -z $MAX ]] && MAX=31

BailOut() {
  [[ -n $1 ]] && echo "$(basename $0): $*"
  exit 1
}

cleanUp() {
  { set +x; } 2>/dev/null
  [[ -e $TMP ]] && rm -rf $TMP
}
trap cleanUp EXIT

commitCSV() {
  echo "$(basename $0): $FUNCNAME $BRAND $ENVIRO $TICKET"
  egrep -iv "=====|<<<<<|>>>>>" $HIST_CSV | sort -u > $HIST_CSV.new
  mv $HIST_CSV.new $HIST_CSV

  egrep -iv "=====|<<<<<|>>>>>" $JIRA_CSV | sort -u > $JIRA_CSV.new
  mv $JIRA_CSV.new $JIRA_CSV

  git stash -q >/dev/null 2>&1
  git pull -q --rebase
  git stash pop -q >/dev/null 2>&1
  git add $JIRA_CSV $HIST_CSV >/dev/null 2>&1
  git commit -q -m "Update $DATE"
  git push -q
}

[[ -n $1 ]] && ENV_LIST=$(echo "$*" | sed -es/','/' '/g) || SCAN=true

pushd $(pwd) >/dev/null 2>&1
git clone -q --depth 1 $REPO $TMP || BailOut "Can't clone $REPO"
cd $TMP || BailOut "Can't cd to $TMP"

echo "$(basename $0): Tickets=$(wc -l $JIRA_CSV | awk '{ print $1 }')"

NEW=$(date --date "-$DAYS days" '+%Y%m%d')
OLD=$(date --date "-$MAX days" '+%Y%m%d')
if [[ $SCAN =~ true ]]
then
  echo "+ Scan existing tickets"
  #ps -ef | grep "$(basename $0)" | egrep -iv "grep|$$|basename"

  sort -u -t, -k4r $JIRA_CSV | awk -F, '{ print $2,$3,$4,$1 }' |
  while read b e t d
  do  
    [[ -z $t ]] && continue

    # convert date to a numerical value
    d=$(sed -es/-//g -es/://g <<< $d | awk '{ print $1 }')

    # close tickets over MAX days old
    if [[ $d -lt $OLD ]]
    then
      echo "$t is over $MAX days old, closing" 
      jira-label $t ops:ticket-cleanup
      jira-close -t $t -c "Ticket is over $MAX days old - auto-closing"
      grep -iv "$t" $JIRA_CSV > $JIRA_CSV.new
      mv $JIRA_CSV.new $JIRA_CSV
      commitCSV
      continue 
    fi

    # skip tickets between NEW and MAX days old
    [[ $d -gt $NEW ]] || { echo "$t is over $DAYS days old, skipping re-check"; continue; }

    echo "***"
    echo "* $(basename $0): re-check $t $b $e https://jira.wsgc.com/browse/$t $d"
    chk-golden-paths $b $e 
    echo

    git stash -q >/dev/null 2>&1
    git pull -q --rebase
    git stash pop -q >/dev/null 2>&1
  done

  exit 0
fi

# this bulk-closes all of the old tickets
if [[ $CLEAR =~ true ]]
then
  for ticket in $(grep -iv $(date +'%Y-%m-%d') $JIRA_CSV | awk -F, '{ print $4 }')
  do
    echo "$(basename $0) Close old $ticket "
    jira-label $ticket ops:ticket-cleanup
    jira-close -t $ticket -c "Closing old Golden Path tickets" >/dev/null 2>&1
  
    b=$(grep $ticket $JIRA_CSV | awk -F, '{ print $2 }')
    e=$(grep $ticket $JIRA_CSV | awk -F, '{ print $3 }')
    echo "$DATE,$ticket,$b,$e,cleanup," >> $HIST_CSV

    grep -iv "$ticket" $JIRA_CSV > $JIRA_CSV.new
    mv $JIRA_CSV.new $JIRA_CSV
  done
  commitCSV
  exit 0
fi

for ENVIRO in $ENV_LIST
do
  git stash -q >/dev/null >/dev/null 2>&1
  git pull -q --rebase >/dev/null 2>&1
  git stash pop -q >/dev/null >/dev/null 2>&1

  echo "+ $ENVIRO"
  for BRAND in $(get-brand-list $ENVIRO)
  do
    OUT=$(basename $0)-$BRAND.out
    echo "  - $BRAND" > $OUT
    chk-golden-paths $BRAND $ENVIRO create >> $OUT 2>&1 &
    sleep 5
  done

  wait 

  for BRAND in $(get-brand-list $ENVIRO)
  do
    OUT=$(basename $0)-$BRAND.out
    cat $OUT
    rm -f $OUT
  done
done

commitCSV

echo "$(basename $0): Tickets: $(wc -l $JIRA_CSV | awk '{ print $1 }')"

popd >/dev/null 2>&1

exit 0
