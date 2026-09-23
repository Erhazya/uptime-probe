#!/usr/bin/env bash
# Daily summary, run by GitHub Actions just after midnight UTC.
#
# For one UTC day (yesterday by default), it computes per target the number
# of incidents, the minutes of outage and the availability, from the
# "incident" issues opened by probe.sh, and appends one line per target to
# history/YYYY-MM.md. The daily commit also keeps the repository active, so
# that GitHub does not suspend its scheduled workflows after 60 days.
set -euo pipefail

TARGETS_FILE=${TARGETS_FILE:-targets.json}
DAY=${DAY:-$(date -u -d yesterday +%F)}
[[ $DAY =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "DAY must be YYYY-MM-DD" >&2; exit 1; }
FILE="history/${DAY:0:7}.md"

start=$(date -u -d "$DAY" +%s)
end=$((start + 86400))

# Outage seconds and incident count per target, within [start, end).
stats=$(gh issue list --label incident --state all --limit 500 \
  --json title,createdAt,closedAt |
  jq --argjson s "$start" --argjson e "$end" '
    map({target: (.title | capture("^\\[(?<t>[^]]+)\\]").t),
         from: (.createdAt | fromdateiso8601),
         to: (if .closedAt then (.closedAt | fromdateiso8601) else now end)})
    | map(.overlap = ([.to, $e] | min) - ([.from, $s] | max))
    | map(select(.overlap > 0))
    | group_by(.target)
    | map({key: .[0].target, value: {count: length, seconds: (map(.overlap) | add)}})
    | from_entries')

mkdir -p history
if [[ ! -f $FILE ]]; then
  printf '# %s\n\n| Day (UTC) | Target | Incidents | Outage | Availability |\n|---|---|---|---|---|\n' \
    "${DAY:0:7}" >"$FILE"
fi
if grep -q "^| $DAY |" "$FILE"; then
  echo "$DAY is already summarised in $FILE"
  exit 0
fi

jq -r --arg day "$DAY" --argjson st "$stats" '
  .[] | .name as $n | ($st[$n] // {count: 0, seconds: 0}) as $x
  | "| \($day) | \($n) | \($x.count) | \($x.seconds / 60 | floor) min | \((1 - $x.seconds / 86400) * 10000 | round / 100) % |"' \
  "$TARGETS_FILE" >>"$FILE"
tail -n +5 "$FILE" | grep "^| $DAY |"
