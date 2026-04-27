#!/bin/bash
set -e

# Mirror the host's home directory inside the container so that absolute
# paths stored in shared config (~/.claude/settings.json hooks, statusLine
# commands, plugin paths, etc.) resolve. The host bind-mounts ~/.claude into
# /home/node/.claude, but a path like /Users/jake/.claude/hooks/foo.sh
# baked into settings.json doesn't exist inside the container without this.
if [[ -n "${HOST_HOME:-}" && "$HOST_HOME" != "/home/node" ]]; then
    if [[ -e "$HOST_HOME" && ! -L "$HOST_HOME" ]]; then
        echo "safe-claude: $HOST_HOME already exists in container; not creating symlink." >&2
    else
        mkdir -p "$(dirname "$HOST_HOME")"
        ln -sfn /home/node "$HOST_HOME"
    fi
fi

exec gosu node "$@"
