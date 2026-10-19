#!/bin/bash
# E10.1, E11: tells The Companion what each Claude Code or Codex session is doing.
#
#   agent-status.sh <claude|codex> <waiting|finished|working|limited|ended|pretool> [reason]
#
# Run by the agents' hooks with the hook's JSON on stdin. Each live session has one file,
# /tmp/the-companion-<uid>/agents/<agent>-<session_id>.json, holding its latest state, which the
# app watches (E10.1, E11); ended deletes it. For limited (out of usage), the reset time is taken from the error
# message ("... · resets 3:45pm") when it's there. Writes go through a temp file and a rename,
# so the app never reads half a file.
# Always exits 0 and prints nothing: a hook that fails must never get in the agent's way.

agent="$1" state="$2" reason="$3"
input="$(cat)"
# /tmp rather than the repo: Codex runs hooks inside its sandbox, which can write to the session's
# own folder and /tmp but not here. THE_LIST_DATA_DIR overrides it, for tests.
if [ -n "$THE_LIST_DATA_DIR" ]; then dir="$THE_LIST_DATA_DIR/agents"; else dir="/tmp/the-companion-$(/usr/bin/id -u)/agents"; fi
jq=/usr/bin/jq
[ -x "$jq" ] || jq="$(command -v jq)" || exit 0

session="$(printf '%s' "$input" | "$jq" -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')"
case "$agent" in claude | codex) ;; *) exit 0 ;; esac
[ -n "$session" ] || exit 0
file="$dir/$agent-$session.json"

# pretool: one PreToolUse hook for every tool. Asking me a question is waiting; anything else is
# work. (Two hooks on the same event would run at once and race.)
if [ "$state" = pretool ]; then
    if [ "$(printf '%s' "$input" | "$jq" -r '.tool_name // empty' 2>/dev/null)" = AskUserQuestion ]; then
        state=waiting reason="has a question"
    else
        state=working reason=""
    fi
fi

case "$state" in
ended)
    rm -f "$file"
    ;;
waiting | finished | working | limited)
    /bin/mkdir -p -m 700 "$dir" 2>/dev/null || exit 0
    tmp="$(/usr/bin/mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || {
        echo "$(/bin/date) $agent $state: can't write to $dir" >>"$dir/../hook-errors.log" 2>/dev/null
        exit 0
    }
    if printf '%s' "$input" | "$jq" -c \
        --arg agent "$agent" --arg state "$state" --arg reason "$reason" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{agent: $agent, session: .session_id, state: $state,
          reason: (if $reason != "" then $reason else (.message // "") end),
          cwd: (.cwd // ""), at: $at,
          resets: ((.last_assistant_message // "") | (capture("resets (?<r>[^·\n)]+)")? // {r: ""}) | .r | rtrimstr(" "))}' >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
    ;;
esac
exit 0
