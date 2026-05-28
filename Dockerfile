FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    procps \
    sudo \
    fzf \
    zsh \
    wget \
    ca-certificates \
    gnupg2 \
    jq \
    unzip \
    ripgrep \
    fd-find \
    less \
    gh \
    curl \
    build-essential \
    libssl-dev \
    pkg-config \
    openssh-client \
    zip \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    pipx \
    gosu \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Enable corepack so pnpm + yarn are available on demand
# (dao-dao-ui is pnpm/turborepo; website/ is yarn/Nuxt 3).
RUN corepack enable

# Install Playwright system dependencies for vitest browser mode
# (https://vitest.dev/guide/browser/). Browser binaries are downloaded
# to PLAYWRIGHT_BROWSERS_PATH in the user layer below.
RUN npm install -g playwright \
    && npx --yes playwright install-deps \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install delta
RUN ARCH=$(dpkg --print-architecture) \
    && wget -q "https://github.com/dandavison/delta/releases/download/0.18.2/git-delta_0.18.2_${ARCH}.deb" \
    && dpkg -i "git-delta_0.18.2_${ARCH}.deb" \
    && rm "git-delta_0.18.2_${ARCH}.deb"

# Install just
RUN curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
    | bash -s -- --to /usr/local/bin

# Install mise (polyglot tool/version manager — https://github.com/jdx/mise)
RUN curl https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Install uv (fast Python package/project manager — https://github.com/astral-sh/uv).
# Installs uv + uvx into /usr/local/bin so it's available system-wide without
# touching $HOME. INSTALLER_NO_MODIFY_PATH skips the shell-rc edits the
# installer would otherwise make for an interactive user install.
RUN curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh

# Install Go (pinned). Required for Cosmos SDK / Juno chain (`make build`,
# `make proto-gen`, `make ictest-*`), polytone simtests, and the
# osmosis-test-tube build script used by `cargo test --features test-tube`.
ARG GO_VERSION=1.25.2
RUN ARCH=$(dpkg --print-architecture) \
    && wget -q "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -O /tmp/go.tar.gz \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz

# Install Docker CLI. The container uses the host's docker daemon via a
# bind-mounted /var/run/docker.sock; the entrypoint reconciles the in-image
# `docker` group GID with the host socket's GID at startup.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install protoc (Cosmos SDK proto regeneration)
ARG PROTOC_VERSION=27.3
RUN ARCH=$(dpkg --print-architecture); [ "$ARCH" = "amd64" ] && PARCH=x86_64 || PARCH=aarch_64; \
    wget -q "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOC_VERSION}/protoc-${PROTOC_VERSION}-linux-${PARCH}.zip" -O /tmp/protoc.zip \
    && unzip -q /tmp/protoc.zip -d /usr/local \
    && rm /tmp/protoc.zip

# Install buf (proto linting + code-gen front-end used by Cosmos SDK)
RUN curl -sSL "https://github.com/bufbuild/buf/releases/latest/download/buf-$(uname -s)-$(uname -m)" -o /usr/local/bin/buf \
    && chmod +x /usr/local/bin/buf

# Install libwasmvm (CosmWasm VM shared library) — required by
# `cargo test --features test-tube` in dao-contracts and by the cgo-linked
# Juno chain (Path B target: wasmvm v3.x).
ARG WASMVM_VERSION=v3.0.4
RUN ARCH=$(dpkg --print-architecture); [ "$ARCH" = "amd64" ] && WASMARCH=x86_64 || WASMARCH=aarch64; \
    wget -q "https://github.com/CosmWasm/wasmvm/releases/download/${WASMVM_VERSION}/libwasmvm.${WASMARCH}.so" -O "/usr/lib/libwasmvm.${WASMARCH}.so" \
    && ldconfig

# Set up non-root user and directories
# Ubuntu 24.04 ships with a default 'ubuntu' user/group at UID/GID 1000;
# remove it first so we can reclaim that ID for our 'node' user.
ARG USERNAME=node
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd --gid 1000 $USERNAME \
    && useradd --uid 1000 --gid 1000 -m -s /bin/zsh $USERNAME \
    && groupadd -f docker \
    && usermod -aG docker $USERNAME \
    && mkdir -p /usr/local/share/npm-global /workspace /home/node/.claude /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R $USERNAME:$USERNAME /usr/local/share/npm-global /workspace /home/node/.claude /commandhistory

USER $USERNAME
WORKDIR /workspace

# Git identity is set at runtime via GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL,
# GIT_COMMITTER_NAME, and GIT_COMMITTER_EMAIL environment variables
# passed by the safebox dispatcher from the host's git config.

# Environment setup
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV SHELL=/bin/zsh
ENV HISTFILE=/commandhistory/.bash_history
ENV PROMPT_COMMAND='history -a'

# pnpm: resolve platform-optional native deps (rollup, esbuild, swc, lightningcss)
# for both linux + darwin and arm64 + x64. Without this, a `pnpm install` run
# inside the container against a lockfile generated on macOS won't fetch
# `@rollup/rollup-linux-arm64-gnu` etc. and vitest/vite crash on import.
# https://pnpm.io/settings#supportedarchitectures
RUN printf '%s\n' \
    'supportedArchitectures[os][]=linux' \
    'supportedArchitectures[os][]=darwin' \
    'supportedArchitectures[cpu][]=arm64' \
    'supportedArchitectures[cpu][]=x64' \
    'supportedArchitectures[libc][]=glibc' \
    'supportedArchitectures[libc][]=musl' \
    > /home/node/.npmrc \
    && chown node:node /home/node/.npmrc

# Make python3 available as python
ENV PATH="/home/node/.local/bin:$PATH"

# Go toolchain paths (Go itself installed in the system layer above)
ENV GOPATH=/home/node/go
ENV PATH=$PATH:/usr/local/go/bin:/home/node/go/bin

# Install Rust and WebAssembly toolchain
ENV CARGO_HOME=/home/node/.cargo
ENV RUSTUP_HOME=/home/node/.rustup
ENV PATH=$PATH:/home/node/.cargo/bin
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path \
    && rustup target add wasm32-unknown-unknown wasm32-wasip1 wasm32-wasip2 \
    && cargo install wasm-tools cargo-component wit-bindgen-cli

# Install Foundry (forge, cast, anvil, chisel)
ENV FOUNDRY_DIR=/home/node/.foundry
ENV PATH=$PATH:/home/node/.foundry/bin
RUN curl -L https://foundry.paradigm.xyz | bash \
    && /home/node/.foundry/bin/foundryup

# Install qmd
RUN npm install -g @tobilu/qmd

# Install wrangler (Cloudflare Workers CLI — used by indexer-proxy/)
RUN npm install -g wrangler

# Download Playwright browsers for vitest browser mode + UI testing.
# System deps installed in the system layer above; this fetches the
# Chromium/Firefox/WebKit binaries into a shared cache dir.
ENV PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright
RUN playwright install chromium firefox webkit

# Install zsh configuration
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.0/zsh-in-docker.sh)" -- \
    -t robbyrussell \
    -p git \
    -p fzf \
    -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
    -a "source /usr/share/doc/fzf/examples/completion.zsh" \
    -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    -a 'eval "$(mise activate zsh)"' \
    -x

# --- Agent harnesses ---------------------------------------------------------
# Each harness gets its own RUN so adding a new one (or bumping versions)
# invalidates only that layer and the ones below it. Ordered most-stable to
# most-volatile: Claude first (most users), Codex second, Pi last.

# Install Claude Code via native installer (auto-updates)
# Falls back to npm install if the native installer is rate-limited
ARG CLAUDE_VERSION=latest
RUN curl -fsSL https://claude.ai/install.sh | bash \
    || npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}

# Install OpenAI Codex CLI. CODEX_HOME tells codex to use the bind-mounted
# ~/.codex dir inside the container, so sessions and auth persist across runs.
ARG CODEX_VERSION=latest
ENV CODEX_HOME=/home/node/.codex
RUN npm install -g @openai/codex@${CODEX_VERSION}

# Install pi.dev coding agent. `--ignore-scripts` is the install recipe
# documented by upstream — keep it. Pi auto-discovers ~/.pi/agent/ and the
# AGENTS.md / SYSTEM.md chain from CWD upward; no env var needed.
ARG PI_VERSION=latest
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION}

VOLUME /commandhistory

# Entrypoint runs as root to mirror the host's home path inside the container
# (so absolute paths in shared ~/.claude config resolve), then drops to node.
USER root
COPY entrypoint.sh /usr/local/bin/safebox-entrypoint.sh
RUN chmod +x /usr/local/bin/safebox-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/safebox-entrypoint.sh"]
