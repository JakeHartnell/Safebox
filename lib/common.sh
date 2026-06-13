# shellcheck shell=bash
#
# Shared helpers for the `safebox` dispatcher.
#
# Sourced by /workspace/safebox. Functions exported here keep the dispatcher
# focused on per-harness wiring (mounts, launch command) rather than the
# generic plumbing (env loading, image build, git/GH/docker-socket forwarding).

IMAGE_NAME="safebox:latest"
LEGACY_IMAGE_NAME="safebox:latest"
CONFIG_DIR_DEFAULT="${XDG_CONFIG_HOME:-$HOME/.config}/safebox"
LEGACY_CONFIG_DIR_DEFAULT="${XDG_CONFIG_HOME:-$HOME/.config}/safebox"

err() {
    echo "safebox: $*" >&2
}

die() {
    err "$*"
    exit 1
}

print_usage() {
    cat <<'EOF'
Usage: safebox <harness> [--rebuild] [--mount SRC[:DEST]] ... [-- <harness args>]

Runs a coding-agent harness inside a Docker sandbox. The current directory is
mounted as /workspace inside the container; the harness's host config dir is
mounted too so sessions persist across runs.

Harnesses:
  claude    Anthropic Claude Code (--dangerously-skip-permissions)
  codex     OpenAI Codex CLI (--dangerously-bypass-approvals-and-sandbox)
  pi        pi.dev coding agent (permissionless by design)

Flags:
  --rebuild            Force a fresh Docker image build. Can run standalone
                       (`safebox --rebuild`) since the image is shared across
                       harnesses, or alongside a harness to rebuild then launch.
  --mount SRC[:DEST]   Mount an extra host path into the container.
                       If DEST is omitted, SRC is used as the destination.
                       May be repeated.
  --                   Everything after this is appended to the harness's
                       launch command verbatim.

Env file (optional, must be chmod 600):
  $XDG_CONFIG_HOME/safebox/.env              loaded before container start

Examples:
  safebox --rebuild
  safebox claude
  safebox codex --mount /tmp/data
  safebox pi -- --model claude-sonnet-4-6
EOF
}

# Load a single env file, refusing if it isn't chmod 600 (it typically holds
# tokens). Silent if the file is absent.
_load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local mode
    mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo "")"
    if [[ -n "$mode" && "${mode: -2}" != "00" ]]; then
        die "$file has mode $mode — run 'chmod 600 $file'"
    fi

    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
}

# Load ~/.config/safebox/.env if present. Falls back to the legacy
# ~/.config/safebox/.env path with a one-line hint so the user knows
# to migrate.
load_env() {
    local config_dir="${SAFEBOX_CONFIG_DIR:-$CONFIG_DIR_DEFAULT}"

    if [[ -f "$config_dir/.env" ]]; then
        _load_env_file "$config_dir/.env"
    elif [[ -f "$LEGACY_CONFIG_DIR_DEFAULT/.env" ]]; then
        err "reading legacy $LEGACY_CONFIG_DIR_DEFAULT/.env — move to $config_dir/.env to silence this"
        _load_env_file "$LEGACY_CONFIG_DIR_DEFAULT/.env"
    fi
}

# Validate the user's --mount specs and emit `-v src:dest` flag pairs on stdout
# (one flag per line, suitable for `mapfile`).
resolve_mounts() {
    local spec src dest
    for spec in "$@"; do
        if [[ "$spec" == *:* ]]; then
            src="${spec%%:*}"
            dest="${spec#*:}"
        else
            src="$spec"
            dest="$spec"
        fi

        [[ -n "$src" ]] || die "malformed mount spec (empty src): $spec"
        [[ -e "$src" ]] || die "mount source does not exist: $src"

        src="$(readlink -f "$src")"
        [[ -n "$dest" ]] || dest="/mnt/$(basename "$src")"

        if [[ "$src" == "$PWD" ]]; then
            err "--mount $spec: already mounted as /workspace, skipping"
            continue
        fi
        if [[ "$src" == "$(readlink -f "$HOME/.claude" 2>/dev/null || echo /nonexistent)" ]]; then
            err "--mount $spec: ~/.claude already mounted, skipping"
            continue
        fi

        printf '%s\n%s\n' "-v" "$src:$dest"
    done
}

# Emit `-e KEY=VAL` lines for git author identity, preferring explicit env
# vars over `git config --global`.
git_env_flags() {
    local name email
    name="${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-$(git config --global user.name 2>/dev/null || true)}}"
    email="${GIT_AUTHOR_EMAIL:-${GIT_COMMITTER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}}"

    if [[ -n "$name" ]]; then
        printf '%s\n%s\n%s\n%s\n' "-e" "GIT_AUTHOR_NAME=$name" "-e" "GIT_COMMITTER_NAME=$name"
    fi
    if [[ -n "$email" ]]; then
        printf '%s\n%s\n%s\n%s\n' "-e" "GIT_AUTHOR_EMAIL=$email" "-e" "GIT_COMMITTER_EMAIL=$email"
    fi
}

# Emit `-e KEY=VAL` lines for GitHub credentials forwarded into the container.
gh_env_flags() {
    if [[ -n "${GH_TOKEN:-}" ]]; then
        printf '%s\n%s\n' "-e" "GH_TOKEN=$GH_TOKEN"
    fi
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        printf '%s\n%s\n' "-e" "GITHUB_TOKEN=$GITHUB_TOKEN"
    fi
    if [[ -n "${GH_USER:-}" ]]; then
        printf '%s\n%s\n' "-e" "GH_USER=$GH_USER"
    fi
}

# Emit `-v` lines mounting the host docker socket if one is present, so
# `docker` inside the container drives the host daemon.
docker_socket_flags() {
    if [[ -S /var/run/docker.sock ]]; then
        printf '%s\n%s\n' "-v" "/var/run/docker.sock:/var/run/docker.sock"
    fi
}

# Emit `-e KEY=VAL` lines for whichever provider API keys are currently set on
# the host. Lets pi (and codex via custom providers) pick up host-side keys
# without forwarding the user's entire environment.
provider_api_env_flags() {
    local key
    for key in ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY GEMINI_API_KEY \
               GROQ_API_KEY MISTRAL_API_KEY AZURE_OPENAI_API_KEY \
               AWS_BEDROCK_API_KEY DEEPSEEK_API_KEY; do
        if [[ -n "${!key:-}" ]]; then
            printf '%s\n%s\n' "-e" "$key=${!key}"
        fi
    done
}

# Build the image if it's missing or --rebuild was passed.
ensure_image() {
    local rebuild="$1" script_dir="$2"
    if [[ "$rebuild" == "true" ]] || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
        echo "Building $IMAGE_NAME..."
        docker build -t "$IMAGE_NAME" "$script_dir"
    fi
}

# One-time nudge if the old image is still on disk after the rename.
legacy_image_hint() {
    if docker image inspect "$LEGACY_IMAGE_NAME" &>/dev/null; then
        err "legacy image '$LEGACY_IMAGE_NAME' detected — 'docker rmi $LEGACY_IMAGE_NAME' to reclaim space"
    fi
}
