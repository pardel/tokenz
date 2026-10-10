#!/bin/zsh
# Claude Code status line that feeds Tokenz its Claude plan percentages.
#
# Claude Code passes a JSON object to the status line command on stdin. This
# script keeps only its `rate_limits` (percentages and reset times) and saves
# them to ~/.claude/tokenz-rate-limits.json, readable by you alone. It then
# prints a short status line.
#
# Every open Claude Code session runs its status line with the limits from its
# own last response, so a session left idle passes on older figures. A saved
# window therefore stays when the new reading is for a window that has ended
# while the saved one has not, or is no higher for the same window: usage
# within a window only grows. Otherwise the newest reading wins, which follows
# a switch to another account.
#
# Use it as your status line, in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/tokenz-statusline.sh" }
# or, from a status line script you already have, pass it the same input:
#   printf '%s\n' "$input" | ~/.claude/tokenz-statusline.sh > /dev/null
#
# Claude Code sends `rate_limits` only on Pro and Max plans, and only after the
# session's first response. Without it, the saved file is left as it was.

zmodload zsh/datetime
input=$(cat)
feed="${TOKENZ_FEED:-$HOME/.claude/tokenz-rate-limits.json}"

value() { print -r -- "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null }
saved() { /usr/bin/plutil -extract "$1" raw -o - "$feed" 2>/dev/null }
number() { [[ $1 =~ '^[0-9]+(\.[0-9]+)?$' ]] }
ended() { [[ -n $1 ]] && (( $1 <= EPOCHSECONDS )) }
# Whether the saved window stays against this session's reading.
stale() {
    number $kept || return 1
    ended $reset && ! ended $kept_reset && return 0
    [[ -n $reset && -n $kept_reset ]] && (( reset == kept_reset && used <= kept ))
}

windows=() changed=0
for key in five_hour seven_day; do
    used=$(value rate_limits.$key.used_percentage) reset=$(value rate_limits.$key.resets_at)
    kept=$(saved rate_limits.$key.used_percentage) kept_reset=$(saved rate_limits.$key.resets_at)
    number $reset || reset=
    number $kept_reset || kept_reset=
    if number $used && ! stale; then
        [[ $used == $kept && $reset == $kept_reset ]] || changed=1
    elif number $kept; then
        used=$kept reset=$kept_reset
    else
        continue
    fi
    windows+=("\"$key\":{\"used_percentage\":$used${reset:+,\"resets_at\":$reset}}")
done

# Rewritten only when a window changed, so the file's date is when the reading last moved.
if (( changed )); then
    umask 077
    # Write beside the target, then rename, so Tokenz never reads a half-written file.
    if tmp=$(mktemp "${feed:h}/.tokenz-rate-limits.XXXXXX"); then
        print -r -- "{\"rate_limits\":{${(j:,:)windows}}}" > "$tmp" && mv -f "$tmp" "$feed"
    fi
fi

model=$(value model.display_name)
five=$(value rate_limits.five_hour.used_percentage)
week=$(value rate_limits.seven_day.used_percentage)
line=${model:-Claude}
[[ -n $five ]] && line+=" · 5h $(printf '%.0f' "$five")%"
[[ -n $week ]] && line+=" · week $(printf '%.0f' "$week")%"
print -r -- "$line"
