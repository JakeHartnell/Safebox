```
 ____         __        ____  _                 _
/ ___|  __ _ / _| ___  / ___|| | __ _ _   _  __| | ___
\___ \ / _` | |_ / _ \| |    | |/ _` | | | |/ _` |/ _ \
 ___) | (_| |  _|  __/| |___ | | (_| | |_| | (_| |  __/
|____/ \__,_|_|  \___| \____||_|\__,_|\__,_|\__,_|\___|

  Claude Code · --dangerously-skip-permissions · Docker sandbox
```

> Run Claude Code with full autonomy — without giving it full access to your machine.

SafeClaude wraps Claude's `--dangerously-skip-permissions` mode in a Docker container. Claude can freely edit files, run shell commands, and install packages — but only inside the sandbox. Your host system stays safe.

**Your project files are mounted read-write** into the container as `/workspace`, so Claude can see and edit everything in the directory you launch from. Changes are real and immediate — that's the point.

---

## Install

```bash
# Clone the repo
git clone https://github.com/JakeHartnell/SafeClaude.git ~/safe-claude

# Add a symlink so you can call it from anywhere
ln -s ~/safe-claude/safe-claude.sh ~/bin/safe-claude
# (make sure ~/bin is in your PATH)
```

That's it. The Docker image is built automatically on first run.

---

## Usage

```bash
cd /any/project
safe-claude
```

Claude opens with your current directory mounted as `/workspace` inside the container. Your `~/.claude` config and memory persist across sessions.

### Flags

| Flag | Description |
|------|-------------|
| `--rebuild` | Force a fresh Docker image build |
| `--mount SRC[:DEST]` | Mount an extra host path into the container. If `DEST` is omitted, `SRC` is used as the destination path. May be repeated. |
| `--help` | Show usage |

### Git identity

SafeClaude automatically reads your host's `git config --global user.name` and `user.email` and forwards them into the container so commits have the correct author. No manual setup needed — if your host git is configured, the container inherits it.

To override for a single run, set the standard Git environment variables:

```bash
GIT_AUTHOR_NAME="Other Name" GIT_AUTHOR_EMAIL="other@example.com" safe-claude
```

### GitHub credentials (and other secrets)

If `~/.config/safe-claude/.env` exists, SafeClaude auto-loads it before launching the container. Copy `.env.example` to give the agent its own GitHub identity:

```bash
mkdir -p ~/.config/safe-claude
cp .env.example ~/.config/safe-claude/.env
chmod 600 ~/.config/safe-claude/.env
$EDITOR ~/.config/safe-claude/.env   # fill in GH_USER + GH_TOKEN
```

Then just `safe-claude`. Inside the container, `gh` picks up the token automatically and `git push` over HTTPS works via a credential helper wired up by `entrypoint.sh`. SafeClaude refuses to load the file if it isn't `chmod 600`. Override the path with `SAFE_CLAUDE_ENV=/some/other/path`.

---

## What's sandboxed

```
HOST MACHINE                    DOCKER CONTAINER
─────────────────               ─────────────────────────────────
~/other-projects    (hidden)    /workspace        ← your project (r/w)
/etc, /usr, ...     (hidden)    ~/.claude         ← config + memory (r/w)
other users' files  (hidden)    --mount paths     ← your extra mounts (r/w)
                                full internet access
```

**Protected:** everything on your host outside the current project directory.

**Not protected:**
- Your **project files** — Claude can edit them freely (that's the whole point)
- **Network** — the container has full outbound internet so Claude can `npm install`, `git clone`, `curl`, etc.
- **`~/.claude`** — Claude config and memory are mounted so sessions persist across runs

> To disable network access: add `--network none` to the `docker run` call in `safe-claude.sh` (breaks package installs and API calls).

### Mounting extra directories

By default only `$PWD` and `~/.claude` are visible inside the container. Use `--mount` to expose additional host paths — shared libraries, model weights, credential directories, etc. — without opening up the entire filesystem.

```bash
# Auto-mapped: /tmp/my-data is available at /tmp/my-data inside the container
safe-claude --mount /tmp/my-data

# Explicit destination
safe-claude --mount /tmp/my-data:/data

# Multiple mounts
safe-claude --mount /shared/libs --mount /mnt/weights:/weights
```

The source path must exist on the host. If you pass `$PWD` or `~/.claude` as a source, the flag is silently skipped since those are already mounted.

---

## Customizing the environment

Edit `Dockerfile` to add whatever tools your project needs, then rebuild:

```bash
vim ~/safe-claude/Dockerfile
safe-claude --rebuild
```

### Examples by project type

**Rust project:**
```dockerfile
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"
```

**Foundry / Solidity project:**
```dockerfile
RUN curl -L https://foundry.paradigm.xyz | bash && \
    /root/.foundry/bin/foundryup
ENV PATH="/root/.foundry/bin:${PATH}"
```

**Python project:**
```dockerfile
RUN apt-get install -y python3 python3-pip python3-venv
```

Different projects need different toolchains — the Dockerfile is yours to extend.

### Pin a specific Claude Code version

```bash
docker build --build-arg CLAUDE_VERSION=1.2.3 -t safe-claude:latest ~/safe-claude
```

### Included tools

The default image ships with a broad set of tools:

- **Node.js 22** and npm
- **Python 3** with pip, venv, and pipx
- **Rust** with wasm targets, `wasm-tools`, `cargo-component`, `wit-bindgen-cli`
- **Foundry** (forge, cast, anvil, chisel)
- **[just](https://github.com/casey/just)** — command runner
- **[qmd](https://github.com/tobi/qmd)** — local search engine for docs and notes
- **[GSD](https://github.com/gsd-build/get-shit-done)** — spec-driven development system for Claude Code
- **General:** git, gh, ripgrep, fd, fzf, jq, delta, zsh

---

## Safety model

The sandbox protects your host by isolating Claude's actions inside a container. Claude gets `--dangerously-skip-permissions` so it never stops to ask for approval — it just does the work. The Docker layer is what keeps that safe.

Think of it as: **full autonomy, bounded blast radius.**

### vs. Claude Code's built-in sandbox

Claude Code has its own `/sandbox` feature (using Apple Seatbelt on macOS, bubblewrap on Linux) that restricts bash commands to `$PWD` and proxies network traffic. SafeClaude takes a different approach:

| | Built-in sandbox | SafeClaude (Docker) |
|---|---|---|
| **Isolation scope** | Bash commands only | Entire OS environment |
| **Filesystem** | R/W to `$PWD`, read-only elsewhere | Only `$PWD` and `~/.claude` visible |
| **Network** | Proxied, domain allowlist | Full access (or `--network none`) |
| **Overhead** | Lightweight, native | Full container startup |
| **Customizable env** | No | Yes — edit the Dockerfile |

The built-in sandbox is a good fit for interactive use on your own machine. SafeClaude is better when you want a fully reproducible, customizable environment — or when you're running Claude autonomously and want stronger isolation guarantees.
