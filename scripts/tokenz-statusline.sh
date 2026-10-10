#!/bin/zsh
# Claude Code status line that feeds Tokenz its Claude plan percentages.
#
# Claude Code passes a JSON object to the status line command on stdin. This
# script keeps only its `rate_limits` (percentages and reset times) and saves
# them to ~/.claude/tokenz-rate-limits.json, readable by you alone. It then
# prints a short status line.
#
# Use it as your status line, in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/tokenz-statusline.sh" }
# or, from a status line script you already have, pass it the same input:
#   printf '%s\n' "$input" | ~/.claude/tokenz-statusline.sh > /dev/null
#
# Claude Code sends `rate_limits` only on Pro and Max plans, and only after the
# session's first response. Without it, the saved file is left as it was.

input=$(cat)
feed="${TOKENZ_FEED:-$HOME/.claude/tokenz-rate-limits.json}"

value() { print -r -- "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null }

if limits=$(print -r -- "$input" | /usr/bin/plutil -extract rate_limits json -o - - 2>/dev/null); then
    umask 077
    # Write beside the target, then rename, so Tokenz never reads a half-written file.
    if tmp=$(mktemp "${feed:h}/.tokenz-rate-limits.XXXXXX"); then
        print -r -- "{\"rate_limits\":$limits}" > "$tmp" && mv -f "$tmp" "$feed"
    fi
fi

model=$(value model.display_name)
five=$(value rate_limits.five_hour.used_percentage)
week=$(value rate_limits.seven_day.used_percentage)
line=${model:-Claude}
[[ -n $five ]] && line+=" · 5h $(printf '%.0f' "$five")%"
[[ -n $week ]] && line+=" · week $(printf '%.0f' "$week")%"
print -r -- "$line"
