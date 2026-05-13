#!/usr/bin/env bash
set -euo pipefail

# Resolve the directory containing this script (follows symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Auto-load secrets/env (GH_TOKEN, GH_USER, etc.) from a fixed location so
# `safe-claude` works without the user having to export vars in their shell rc.
# Honors XDG_CONFIG_HOME, falls back to ~/.config/safe-claude/.env.
SAFE_CLAUDE_ENV="${SAFE_CLAUDE_ENV:-${XDG_CONFIG_HOME:-$HOME/.config}/safe-claude/.env}"
if [[ -f "$SAFE_CLAUDE_ENV" ]]; then
    # Refuse group/world-accessible secrets files — these typically contain tokens.
    SAFE_CLAUDE_ENV_MODE="$(stat -c '%a' "$SAFE_CLAUDE_ENV" 2>/dev/null || stat -f '%Lp' "$SAFE_CLAUDE_ENV" 2>/dev/null || echo "")"
    if [[ -n "$SAFE_CLAUDE_ENV_MODE" && "${SAFE_CLAUDE_ENV_MODE: -2}" != "00" ]]; then
        echo "safe-claude: $SAFE_CLAUDE_ENV has mode $SAFE_CLAUDE_ENV_MODE — run 'chmod 600 $SAFE_CLAUDE_ENV'" >&2
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    source "$SAFE_CLAUDE_ENV"
    set +a
fi

IMAGE_NAME="safe-claude:latest"
REBUILD=false
EXTRA_MOUNTS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)
            REBUILD=true
            shift
            ;;
        --mount)
            if [[ $# -lt 2 ]]; then
                echo "safe-claude: --mount requires an argument" >&2
                exit 1
            fi
            EXTRA_MOUNTS+=("$2")
            shift 2
            ;;
        --mount=*)
            EXTRA_MOUNTS+=("${1#--mount=}")
            shift
            ;;
        --help|-h)
            echo "Usage: safe-claude [--rebuild] [--mount SRC[:DEST]] ..."
            echo ""
            echo "Runs Claude Code with --dangerously-skip-permissions inside a Docker container."
            echo "The current directory is mounted as /workspace inside the container."
            echo ""
            echo "Flags:"
            echo "  --rebuild            Force a fresh Docker image build"
            echo "  --mount SRC[:DEST]   Mount an extra host path into the container."
            echo "                       If DEST is omitted, SRC is used as the destination."
            echo "                       May be repeated for multiple mounts."
            echo ""
            echo "Env file:"
            echo "  Variables in \$XDG_CONFIG_HOME/safe-claude/.env (default"
            echo "  ~/.config/safe-claude/.env) are auto-loaded. Use it for GH_TOKEN,"
            echo "  GH_USER, etc. Override the path with SAFE_CLAUDE_ENV."
            echo "  The file must be chmod 600."
            exit 0
            ;;
        *)
            echo "safe-claude: unknown option: $1" >&2
            echo "Run 'safe-claude --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Validate and build extra mount flags
EXTRA_MOUNT_FLAGS=()
for spec in "${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"}"; do
    if [[ "$spec" == *:* ]]; then
        src="${spec%%:*}"
        dest="${spec#*:}"
    else
        src="$spec"
        dest="$spec"
    fi

    if [[ -z "$src" ]]; then
        echo "safe-claude: malformed mount spec (empty src): $spec" >&2
        exit 1
    fi
    if [[ ! -e "$src" ]]; then
        echo "safe-claude: mount source does not exist: $src" >&2
        exit 1
    fi

    src="$(readlink -f "$src")"

    # Default dest to /mnt/<basename> when not specified
    if [[ -z "$dest" ]]; then
        dest="/mnt/$(basename "$src")"
    fi

    # Skip if already mounted by default
    if [[ "$src" == "$PWD" ]]; then
        echo "safe-claude: --mount $spec: already mounted as /workspace, skipping" >&2
        continue
    fi
    if [[ "$src" == "$(readlink -f "$HOME/.claude")" ]]; then
        echo "safe-claude: --mount $spec: ~/.claude already mounted, skipping" >&2
        continue
    fi

    EXTRA_MOUNT_FLAGS+=(-v "$src:$dest")
done

# Build image if it doesn't exist or --rebuild was requested
if $REBUILD || ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Building $IMAGE_NAME..."
    BUILD_FLAGS=()
    BUILD_TMP_FILES=()
    cleanup_build_tmp() {
        for f in "${BUILD_TMP_FILES[@]+"${BUILD_TMP_FILES[@]}"}"; do
            rm -f "$f"
        done
    }
    trap cleanup_build_tmp EXIT INT TERM HUP

    # Forward tau auth credentials as BuildKit secrets if present. The
    # Dockerfile skips the tau install layer when either secret is missing.
    # Secrets are mounted only for the duration of their RUN step — they
    # don't land in image layers or `docker history`.
    if [[ -n "${TAU_AUTH_LABEL:-}" ]]; then
        tau_label_file=$(mktemp /tmp/tau-label-XXXXXX)
        chmod 600 "$tau_label_file"
        printf '%s' "$TAU_AUTH_LABEL" > "$tau_label_file"
        BUILD_TMP_FILES+=("$tau_label_file")
        BUILD_FLAGS+=(--secret "id=tau_label,src=$tau_label_file")
    fi
    if [[ -n "${TAU_PASSWORD:-}" ]]; then
        tau_password_file=$(mktemp /tmp/tau-password-XXXXXX)
        chmod 600 "$tau_password_file"
        printf '%s' "$TAU_PASSWORD" > "$tau_password_file"
        BUILD_TMP_FILES+=("$tau_password_file")
        BUILD_FLAGS+=(--secret "id=tau_password,src=$tau_password_file")
    fi
    # TAU_API_URL is not sensitive; pass as a build arg.
    if [[ -n "${TAU_API_URL:-}" ]]; then
        BUILD_FLAGS+=(--build-arg "TAU_API_URL=$TAU_API_URL")
    fi

    # BuildKit is the default on Docker 23+, but force it on so --secret works
    # on older daemons too.
    DOCKER_BUILDKIT=1 docker build "${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}" -t "$IMAGE_NAME" "$SCRIPT_DIR"

    cleanup_build_tmp
    trap - EXIT INT TERM HUP
fi

# Forward git identity into the container.
# Explicit env vars (GIT_AUTHOR_NAME, etc.) take precedence over host git config.
GIT_USER_NAME="${GIT_AUTHOR_NAME:-${GIT_COMMITTER_NAME:-$(git config --global user.name 2>/dev/null || true)}}"
GIT_USER_EMAIL="${GIT_AUTHOR_EMAIL:-${GIT_COMMITTER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}}"
GIT_ENV_FLAGS=()
if [[ -n "$GIT_USER_NAME" ]]; then
    GIT_ENV_FLAGS+=(-e "GIT_AUTHOR_NAME=$GIT_USER_NAME" -e "GIT_COMMITTER_NAME=$GIT_USER_NAME")
fi
if [[ -n "$GIT_USER_EMAIL" ]]; then
    GIT_ENV_FLAGS+=(-e "GIT_AUTHOR_EMAIL=$GIT_USER_EMAIL" -e "GIT_COMMITTER_EMAIL=$GIT_USER_EMAIL")
fi

# Forward a GitHub token if one is set on the host. `gh` reads GH_TOKEN /
# GITHUB_TOKEN automatically; the entrypoint also wires `git` credential
# helper so HTTPS pushes work from inside the container.
if [[ -n "${GH_TOKEN:-}" ]]; then
    GIT_ENV_FLAGS+=(-e "GH_TOKEN=$GH_TOKEN")
fi
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    GIT_ENV_FLAGS+=(-e "GITHUB_TOKEN=$GITHUB_TOKEN")
fi
if [[ -n "${GH_USER:-}" ]]; then
    GIT_ENV_FLAGS+=(-e "GH_USER=$GH_USER")
fi

# Mount the host docker socket if available, so docker CLI inside the
# container drives the host daemon (needed for cosmwasm/optimizer,
# interchaintest, and the dao-contracts `just deploy-local` flow).
DOCKER_FLAGS=()
if [[ -S /var/run/docker.sock ]]; then
    DOCKER_FLAGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi

# Ensure host-side credential targets exist so Docker bind-mounts them as
# files/dirs rather than creating empty directories in their place.
mkdir -p "$HOME/.claude"
touch "$HOME/.claude.json"

# Persist qmd's cache (GGUF model weights + SQLite index — multi-GB) across
# container rebuilds. Without this, every fresh container re-downloads the
# embedding/reranker/expander models and re-embeds every collection.
mkdir -p "$HOME/.cache/qmd"

# Copy .claude.json to a temp file so the container never writes directly to
# the host file (Docker's macOS filesystem layer can corrupt atomic renames).
CLAUDE_JSON_TMP=$(mktemp /tmp/claude-json-XXXXXX)
cp "$HOME/.claude.json" "$CLAUDE_JSON_TMP"
CONTAINER_NAME="safe-claude-$$"
cleanup() {
    docker stop "$CONTAINER_NAME" &>/dev/null || true
    rm -f "$CLAUDE_JSON_TMP"
}
trap cleanup EXIT INT TERM HUP

# Run Claude inside the container
docker run --rm -it \
    --name "$CONTAINER_NAME" \
    -v "$PWD:/workspace" \
    -v "$HOME/.claude:/home/node/.claude" \
    -v "$CLAUDE_JSON_TMP:/home/node/.claude.json" \
    -v "$HOME/.cache/qmd:/home/node/.cache/qmd" \
    "${EXTRA_MOUNT_FLAGS[@]+"${EXTRA_MOUNT_FLAGS[@]}"}" \
    "${GIT_ENV_FLAGS[@]+"${GIT_ENV_FLAGS[@]}"}" \
    "${DOCKER_FLAGS[@]+"${DOCKER_FLAGS[@]}"}" \
    -e "HOST_HOME=$HOME" \
    -w /workspace \
    "$IMAGE_NAME" \
    claude --dangerously-skip-permissions
EXIT_CODE=$?

# Copy the temp file back only if it is valid JSON (preserves auth/setting
# updates while protecting the host file if the container corrupted it).
if jq empty "$CLAUDE_JSON_TMP" 2>/dev/null; then
    cp "$CLAUDE_JSON_TMP" "$HOME/.claude.json"
else
    echo "safe-claude: container wrote invalid JSON to .claude.json — host file left unchanged." >&2
fi

exit $EXIT_CODE
