#!/usr/bin/env bash
# External uptime probe, run by GitHub Actions every 5 minutes.
#
# For each target in targets.json, it reads the SSH banner. When a target
# stops answering, it opens a GitHub issue labelled "incident"; when the
# target answers again, it comments with the outage length and closes the
# issue. The issues form a public, timestamped log of outages.
#
# Environment:
#   GH_TOKEN               token for the gh CLI (the workflow's GITHUB_TOKEN)
#   DISCORD_WEBHOOK_URL    optional: where alerts are posted
#   HEALTHCHECKS_PING_URL  optional: pinged at the end of every run, so that
#                          healthchecks.io alerts if the probe itself stops
#   DRY_RUN=true           print the actions instead of performing them
set -euo pipefail

TARGETS_FILE=${TARGETS_FILE:-targets.json}
ATTEMPTS=${ATTEMPTS:-3}         # a target is down only if every attempt fails
RETRY_DELAY=${RETRY_DELAY:-10}  # seconds between two attempts
TIMEOUT=${TIMEOUT:-10}          # seconds allowed for one attempt
DRY_RUN=${DRY_RUN:-false}
LABEL=incident

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Run a command, or only print it in dry-run mode.
run() {
  if [[ $DRY_RUN == true ]]; then log "dry-run: $*"; else "$@"; fi
}

# True when the target answers with an SSH banner ("SSH-2.0-...").
# Bash opens the connection itself (/dev/tcp) inside `timeout`,
# so an unreachable host cannot block the run.
ssh_banner_ok() {
  local host=$1 port=$2 banner
  # shellcheck disable=SC2016  # $0 and $1 are expanded by the inner bash
  banner=$(timeout "$TIMEOUT" bash -c \
    'exec 3<>"/dev/tcp/$0/$1" && IFS= read -r line <&3 && printf %s "$line"' \
    "$host" "$port" 2>/dev/null) || return 1
  [[ $banner == SSH-* ]]
}

# True if at least one of $ATTEMPTS attempts succeeds.
is_up() {
  local host=$1 port=$2 i
  for ((i = 1; i <= ATTEMPTS; i++)); do
    ssh_banner_ok "$host" "$port" && return 0
    if ((i < ATTEMPTS)); then sleep "$RETRY_DELAY"; fi
  done
  return 1
}

# Post a message to Discord, if a webhook is configured.
notify() {
  [[ -n ${DISCORD_WEBHOOK_URL:-} ]] || return 0
  run curl -fsS -m 10 -H 'Content-Type: application/json' \
    -d "$(jq -n --arg c "$1" '{content: $c}')" "$DISCORD_WEBHOOK_URL" >/dev/null ||
    log "warning: Discord notification failed"
}

# Number of the open incident issue of a target, or nothing.
open_incident() {
  gh issue list --label "$LABEL" --state open --limit 100 --json number,title \
    --jq ".[] | select(.title | startswith(\"[$1]\")) | .number" | head -n 1
}

# Duration between an ISO 8601 date and now, as "3h07".
elapsed_since() {
  local minutes=$((($(date -u +%s) - $(date -u -d "$1" +%s)) / 60))
  printf '%dh%02d' $((minutes / 60)) $((minutes % 60))
}

main() {
  local now name host port issue created
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while IFS=$'\t' read -r name host port; do
    issue=$(open_incident "$name")
    if is_up "$host" "$port"; then
      log "$name: up"
      if [[ -n $issue ]]; then
        created=$(gh issue view "$issue" --json createdAt --jq .createdAt)
        run gh issue comment "$issue" --body "Back up at $now, after $(elapsed_since "$created")."
        run gh issue close "$issue"
        notify "✅ **$name** is back up ($now), after $(elapsed_since "$created")."
      fi
    else
      log "$name: DOWN"
      if [[ -z $issue ]]; then
        run gh label create "$LABEL" --color B60205 --description "A target stopped answering" --force >/dev/null
        run gh issue create --label "$LABEL" --title "[$name] down since $now" \
          --body "No SSH banner from $host:$port after $ATTEMPTS attempts, ${RETRY_DELAY}s apart. First failure detected at $now (UTC)."
        notify "🔴 **$name** is down since $now (no SSH banner on port $port)."
      fi
    fi
  done < <(jq -r '.[] | [.name, .host, (.port | tostring)] | @tsv' "$TARGETS_FILE")

  if [[ -n ${HEALTHCHECKS_PING_URL:-} ]]; then
    run curl -fsS -m 10 --retry 3 "$HEALTHCHECKS_PING_URL" >/dev/null ||
      log "warning: healthchecks.io ping failed"
  fi
}

main "$@"
