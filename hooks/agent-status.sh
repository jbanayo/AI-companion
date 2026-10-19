#!/bin/bash
# E10.1: tells The Companion when a Claude Code or Codex session is waiting on me.
#
#   agent-status.sh <claude|codex> <waiting|finished|working|ended> [reason]
#
# Run by the agents' hooks with the hook's JSON on stdin. A waiting or finished session gets a
# file, data/agents/<agent>-<session_id>.json, which the app watches; working or ended deletes
# it. Writes go through a temp file and a rename, so the app never reads half a file.
# Always exits 0 and prints nothing: a hook that fails must never get in the agent's way.

agent="$1" state="$2" reason="$3"
input="$(cat)"
dir="${THE_LIST_DATA_DIR:-$(cd "$(dirname "$0")/../data" 2>/dev/null && pwd)}/agents"
jq=/usr/bin/jq
[ -x "$jq" ] || jq="$(command -v jq)" || exit 0

session="$(printf '%s' "$input" | "$jq" -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')"
case "$agent" in claude | codex) ;; *) exit 0 ;; esac
[ -n "$session" ] || exit 0
file="$dir/$agent-$session.json"

case "$state" in
working | ended)
    rm -f "$file"
    ;;
waiting | finished)
    mkdir -p "$dir" || exit 0
    tmp="$(mktemp "$dir/.tmp.XXXXXX")" || exit 0
    if printf '%s' "$input" | "$jq" -c \
        --arg agent "$agent" --arg state "$state" --arg reason "$reason" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{agent: $agent, session: .session_id, state: $state,
          reason: (if $reason != "" then $reason else (.message // "") end),
          cwd: (.cwd // ""), at: $at}' >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
    ;;
esac
exit 0
