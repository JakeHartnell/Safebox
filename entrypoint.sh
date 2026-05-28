#!/bin/bash
set -e

# Mirror the host's home directory inside the container so that absolute
# paths stored in shared config (~/.claude/settings.json hooks, statusLine
# commands, plugin paths, etc.) resolve. The host bind-mounts ~/.claude into
# /home/node/.claude, but a path like /Users/jake/.claude/hooks/foo.sh
# baked into settings.json doesn't exist inside the container without this.
# Only Claude bakes absolute host paths into its config today; the symlink is
# cheap and harmless for codex/pi so we leave it unconditional.
if [[ -n "${HOST_HOME:-}" && "$HOST_HOME" != "/home/node" ]]; then
    if [[ -e "$HOST_HOME" && ! -L "$HOST_HOME" ]]; then
        echo "safebox: $HOST_HOME already exists in container; not creating symlink." >&2
    else
        mkdir -p "$(dirname "$HOST_HOME")"
        ln -sfn /home/node "$HOST_HOME"
    fi
fi

# Reconcile the in-container `docker` group GID with the bind-mounted
# host docker socket so the node user can talk to the daemon without root.
# The host socket's GID varies by platform (Docker Desktop on macOS, native
# Linux, colima, etc.), so we adjust at runtime rather than baking it in.
if [[ -S /var/run/docker.sock ]]; then
    HOST_DOCKER_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo 0)"
    if [[ -n "$HOST_DOCKER_GID" && "$HOST_DOCKER_GID" != "0" ]]; then
        if getent group docker >/dev/null; then
            CURRENT_GID="$(getent group docker | cut -d: -f3)"
            if [[ "$CURRENT_GID" != "$HOST_DOCKER_GID" ]]; then
                # Another group may already own the desired GID (common on
                # macOS where the socket is owned by GID 0 or a high system
                # GID). Try a rename; fall back to recreating the group.
                groupmod -g "$HOST_DOCKER_GID" docker 2>/dev/null \
                    || { groupdel docker && groupadd -g "$HOST_DOCKER_GID" docker; }
            fi
        else
            groupadd -g "$HOST_DOCKER_GID" docker
        fi
        usermod -aG docker node
    fi
fi

# When a GitHub token is forwarded, wire up `git` to use it for HTTPS pushes
# so the agent can `git push` from inside the container. The `gh` CLI picks
# up GH_TOKEN / GITHUB_TOKEN from the environment automatically — no login
# step needed for it.
if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
    GH_USER="${GH_USER:-x-access-token}"
    # The credential helper is a shell function; it reads the token from the
    # environment at invocation time so we don't bake the secret into the
    # config file on disk.
    su node -c "git config --global credential.helper '!f() { echo username=${GH_USER}; echo \"password=\${GH_TOKEN:-\$GITHUB_TOKEN}\"; }; f'"
fi

exec gosu node "$@"
