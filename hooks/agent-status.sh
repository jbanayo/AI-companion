#!/bin/bash
# E10.1, E11, E12.1: tells The Companion what each Claude Code, Codex or Antigravity session is doing.
#
#   agent-status.sh <claude|codex|antigravity> <waiting|finished|working|limited|ended|pretool|stop> [reason]
#
# Run by the agents' hooks with the hook's JSON on stdin. Each live session has one file,
# /tmp/the-companion-<uid>/agents/<agent>-<session_id>.json, holding its latest state, which the
# app watches (E10.1, E11, E12.2); ended deletes it. For limited (out of usage), the reset time is taken from the error
# message ("... · resets 3:45pm") when it's there. Writes go through a temp file and a rename,
# so the app never reads half a file.
# Always exits 0 and must never get in the agent's way. It prints nothing, except `{}` for
# Antigravity, whose hooks have to answer with a JSON object.
# Every early exit leaves a line in hook-errors.log next to the agents folder. With a file named
# `debug` there, every call is logged too, with the start of its input.

agent="$1" state="$2" reason="$3"
input="$(cat)"
[ "$agent" = antigravity ] && printf '{}\n'
# /tmp rather than the repo: Codex runs hooks inside its sandbox, which can write to the session's
# own folder and /tmp but not here. THE_LIST_DATA_DIR overrides it, for tests.
if [ -n "$THE_LIST_DATA_DIR" ]; then dir="$THE_LIST_DATA_DIR/agents"; else dir="/tmp/the-companion-$(/usr/bin/id -u)/agents"; fi
logfile="$dir/../hook-errors.log"
fail() {
    /bin/mkdir -p -m 700 "$dir" 2>/dev/null
    echo "$(/bin/date '+%F %T') $agent $state: $1" >>"$logfile" 2>/dev/null ||
        echo "$(/bin/date '+%F %T') $agent $state: $1 (and $dir isn't writable)" >>"${TMPDIR:-/tmp}/the-companion-hook-errors.log" 2>/dev/null
    exit 0
}
if [ -f "$dir/../debug" ]; then
    echo "$(/bin/date '+%F %T') $agent $state: $(printf '%s' "$input" | head -c 500 | tr '\n' ' ')" >>"$logfile" 2>/dev/null
fi

jq=/usr/bin/jq
[ -x "$jq" ] || jq="$(command -v jq)" || fail "no jq"
case "$agent" in claude | codex | antigravity) ;; *) fail "unknown agent" ;; esac

# Claude and Codex send session_id and cwd; Antigravity sends camelCase conversationId and a list
# of workspacePaths.
session="$(printf '%s' "$input" | "$jq" -r '.session_id // .sessionId // .conversationId // .thread_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-')"
[ -n "$session" ] || fail "no session id in: $(printf '%s' "$input" | head -c 200 | tr '\n' ' ')"
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

# stop: Antigravity's Stop. Background tasks still running is work; out of token budget is
# limited; anything else finished the turn.
if [ "$state" = stop ]; then
    case "$(printf '%s' "$input" | "$jq" -r 'if .fullyIdle == false then "busy" else (.terminationReason // "") end' 2>/dev/null)" in
    busy) state=working reason="" ;;
    MAX_TOKEN_BUDGET_EXCEEDED) state=limited reason="" ;;
    *) state=finished ;;
    esac
fi

case "$state" in
ended)
    rm -f "$file"
    ;;
waiting | finished | working | limited)
    /bin/mkdir -p -m 700 "$dir" 2>/dev/null || fail "can't create $dir"
    tmp="$(/usr/bin/mktemp "$dir/.tmp.XXXXXX" 2>/dev/null)" || fail "can't write to $dir"
    if printf '%s' "$input" | "$jq" -c \
        --arg agent "$agent" --arg state "$state" --arg reason "$reason" --arg session "$session" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{agent: $agent, session: $session, state: $state,
          reason: (if $reason != "" then $reason else (.message // "") end),
          cwd: (.cwd // .workspacePaths[0]? // ""), at: $at,
          resets: ((.last_assistant_message // "") | (capture("resets (?<r>[^·\n)]+)")? // {r: ""}) | .r | rtrimstr(" "))}' >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"
        fail "jq couldn't read the input"
    fi
    ;;
*)
    fail "unknown state"
    ;;
esac
exit 0
