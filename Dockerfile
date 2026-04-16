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
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.x
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install delta
RUN ARCH=$(dpkg --print-architecture) \
    && wget -q "https://github.com/dandavison/delta/releases/download/0.18.2/git-delta_0.18.2_${ARCH}.deb" \
    && dpkg -i "git-delta_0.18.2_${ARCH}.deb" \
    && rm "git-delta_0.18.2_${ARCH}.deb"

# Install just
COPY --from=ghcr.io/casey/just:latest /just /usr/local/bin/just

# Set up non-root user and directories
# Ubuntu 24.04 ships with a default 'ubuntu' user/group at UID/GID 1000;
# remove it first so we can reclaim that ID for our 'node' user.
ARG USERNAME=node
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && groupadd --gid 1000 $USERNAME \
    && useradd --uid 1000 --gid 1000 -m -s /bin/zsh $USERNAME \
    && mkdir -p /usr/local/share/npm-global /workspace /home/node/.claude /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R $USERNAME:$USERNAME /usr/local/share/npm-global /workspace /home/node/.claude /commandhistory

USER $USERNAME
WORKDIR /workspace

# Set git config
RUN git config --global user.email "JakeHartnell@users.noreply.github.com" \
    && git config --global user.name "Jake Hartnell"

# Environment setup
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin
ENV SHELL=/bin/zsh
ENV HISTFILE=/commandhistory/.bash_history
ENV PROMPT_COMMAND='history -a'

# Make python3 available as python
ENV PATH="/home/node/.local/bin:$PATH"

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

# Install zsh configuration
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v1.2.0/zsh-in-docker.sh)" -- \
    -t robbyrussell \
    -p git \
    -p fzf \
    -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
    -a "source /usr/share/doc/fzf/examples/completion.zsh" \
    -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    -x

# Install Claude Code via native installer (auto-updates)
# Falls back to npm install if the native installer is rate-limited
ARG CLAUDE_VERSION=latest
RUN curl -fsSL https://claude.ai/install.sh | bash \
    || npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}

# Install GSD (get-shit-done) globally for Claude Code
ENV CLAUDE_CONFIG_DIR=/home/node/.claude
RUN npx get-shit-done-cc@latest --claude --global

VOLUME /commandhistory
