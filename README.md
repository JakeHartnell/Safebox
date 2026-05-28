```
 ____         __      _
/ ___|  __ _ / _| ___| |__   _____  __
\___ \ / _` | |_ / _ \ '_ \ / _ \ \/ /
 ___) | (_| |  _|  __/ |_) | (_) >  <
|____/ \__,_|_|  \___|_.__/ \___/_/\_\

  Claude · Codex · Pi · YOLO mode · Docker sandbox
```

> Run coding agents in full-autonomy mode — without giving them full access to your machine.

`safebox` wraps three coding-agent harnesses in a Docker container so each one can edit files, run shell commands, and install packages freely, but only inside the sandbox. Your host system stays safe.

```bash
safebox claude    # Anthropic Claude Code, --dangerously-skip-permissions
safebox codex     # OpenAI Codex CLI, --dangerously-bypass-approvals-and-sandbox
safebox pi        # pi.dev coding agent (permissionless by design)
```

The current directory is mounted as `/workspace` inside the container — changes are real and immediate, which is the point. Everything else on your host stays hidden.

---

## Install

```bash
git clone https://github.com/JakeHartnell/safebox.git ~/safebox

# Symlink into your PATH so you can call it from anywhere
ln -s ~/safebox/safebox ~/.local/bin/safebox
# (make sure ~/.local/bin is in your PATH)
```

That's it. The Docker image (`safebox:latest`) builds automatically on first run.

### Migrating from `safe-claude`

`safebox` is the renamed successor of `safe-claude`. If you've been using the old tool:

- The CLI was `safe-claude` → it's now `safebox claude` (or `codex` / `pi`).
- The env file was `~/.config/safe-claude/.env` → move it to `~/.config/safebox/.env`. On the first run, if only the legacy path exists, `safebox` reads it and prints a one-line nudge.
- The image was `safe-claude:latest` → it's now `safebox:latest`. The old image is still on disk after the rename; `docker rmi safe-claude:latest` reclaims the space.
- `~/.claude` and `~/.claude.json` are owned by Claude Code itself and are **not** moved. Your sessions and config carry over untouched.

---

## Usage

```bash
cd /any/project
safebox claude
```

### Flags

| Flag | Description |
|------|-------------|
| `--rebuild` | Force a fresh Docker image build. Can run standalone (`safebox --rebuild`) since the image is shared across all three harnesses, or alongside a harness (`safebox claude --rebuild`) to rebuild then launch. |
| `--mount SRC[:DEST]` | Mount an extra host path into the container. If `DEST` is omitted, `SRC` is used as the destination path. May be repeated. |
| `--` | Everything after this is appended verbatim to the harness's launch command. Useful for `safebox claude -- --resume <sessionId>` or `safebox pi -- --model claude-sonnet-4-6`. |
| `--help` | Show usage |

### Git identity

`safebox` automatically reads your host's `git config --global user.name` and `user.email` and forwards them into the container so commits have the correct author. No manual setup needed — if your host git is configured, the container inherits it.

Override per-run with the standard Git environment variables:

```bash
GIT_AUTHOR_NAME="Other Name" GIT_AUTHOR_EMAIL="other@example.com" safebox claude
```

### Env file (credentials, API keys)

`safebox` loads `~/.config/safebox/.env` if it exists (override the dir with `SAFEBOX_CONFIG_DIR`). One file covers every harness — Docker is the isolation boundary, the env file is just credential plumbing. Use it for `GH_TOKEN`, `GH_USER`, git identity overrides, and any LLM provider API keys you don't want exported in your shell rc.

The file is optional but must be `chmod 600` — `safebox` refuses to load it with broader permissions. Provider keys already exported in your host shell are forwarded automatically, so this file is for the ones you keep out of your shell environment.

To get started:

```bash
mkdir -p ~/.config/safebox
cp .env.example ~/.config/safebox/.env
chmod 600 ~/.config/safebox/.env
$EDITOR ~/.config/safebox/.env
```

Inside the container, `gh` picks the token up automatically and `git push` over HTTPS works via a credential helper wired up by `entrypoint.sh`.

---

## What's sandboxed

```
HOST MACHINE                    DOCKER CONTAINER
─────────────────               ─────────────────────────────────
~/other-projects    (hidden)    /workspace        ← your project (r/w)
/etc, /usr, ...     (hidden)    ~/.claude         ← Claude config (claude only)
other users' files  (hidden)    ~/.codex          ← Codex config (codex only)
                                ~/.pi             ← Pi config    (pi only)
                                --mount paths     ← your extra mounts (r/w)
                                full internet access
```

**Protected:** everything on your host outside the current project directory.

**Not protected:**
- Your **project files** — the agent can edit them freely (that's the whole point)
- **Network** — the container has full outbound internet so the agent can `npm install`, `git clone`, `curl`, etc.
- **The mounted harness config dir** — `~/.claude` for Claude, `~/.codex` for Codex, `~/.pi` for Pi, so sessions and auth persist across runs

> To disable network access: add `--network none` to the `docker run` call in `safebox` (breaks package installs and API calls).

### Mounting extra directories

By default only `$PWD` and the active harness's config dir are visible inside the container. Use `--mount` to expose additional host paths — shared libraries, model weights, credential directories, etc. — without opening up the entire filesystem.

```bash
# Auto-mapped: /tmp/my-data is available at /tmp/my-data inside the container
safebox claude --mount /tmp/my-data

# Explicit destination
safebox claude --mount /tmp/my-data:/data

# Multiple mounts
safebox codex --mount /shared/libs --mount /mnt/weights:/weights
```

The source path must exist on the host. If you pass `$PWD` or `~/.claude` as a source, the flag is silently skipped since those are already mounted.

---

## Per-harness notes

### Claude Code

- Launches `claude --dangerously-skip-permissions`.
- Config dir: `~/.claude/` + `~/.claude.json` (both bind-mounted r/w).
- Auth: `claude /login` on first run; credentials persist in `~/.claude`.
- The `~/.claude.json` mount is routed through a temp file with JSON validation on exit — Docker's macOS filesystem layer can corrupt atomic renames against bind-mounted host files, so we validate the rewritten file before copying it back.
- Includes [GSD](https://github.com/gsd-build/get-shit-done) installed globally for Claude (the other harnesses don't use it).

### Codex CLI

- Launches `codex --dangerously-bypass-approvals-and-sandbox`.
- Config dir: `~/.codex/` (bind-mounted r/w). `CODEX_HOME` is set inside the image so codex respects the mount.
- Auth: `OPENAI_API_KEY` in `~/.config/safebox/.env` (or your host shell), or `codex login` on first run — auth persists in the mounted `~/.codex`.
- If the bypass flag has been renamed upstream (OpenAI has done this twice), verify with `docker run --rm safebox:latest codex --help` and adjust `safebox`.

### Pi

- Launches `pi`. No "skip permissions" flag needed — pi has no built-in permission popups; it's designed to run in a sandbox like this one.
- Config dir: `~/.pi/` (bind-mounted r/w). Pi also auto-discovers `AGENTS.md` / `SYSTEM.md` walking up from the CWD inside `/workspace`.
- Auth: any of `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`, etc. in `~/.config/safebox/.env` (or your host shell) — pi reads whichever provider keys are present.

---

## Customizing the environment

Edit `Dockerfile` to add whatever tools your project needs, then rebuild:

```bash
$EDITOR ~/safebox/Dockerfile
safebox --rebuild
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

### Pin a specific harness version

```bash
docker build \
  --build-arg CLAUDE_VERSION=1.2.3 \
  --build-arg CODEX_VERSION=0.4.0 \
  --build-arg PI_VERSION=0.7.1 \
  -t safebox:latest ~/safebox
```

### Included tools

The default image ships with a broad set of tools:

- **Node.js 22** and npm
- **Python 3** with pip, venv, pipx, and uv
- **Rust** with wasm targets, `wasm-tools`, `cargo-component`, `wit-bindgen-cli`
- **Go** (pinned, for Cosmos SDK and CGO-linked Wasm work)
- **Foundry** (forge, cast, anvil, chisel)
- **Playwright** (browser binaries for vitest browser mode + UI testing)
- **[just](https://github.com/casey/just)** — command runner
- **[mise](https://github.com/jdx/mise)** — polyglot tool/version manager
- **[qmd](https://github.com/tobi/qmd)** — local search engine for docs and notes
- **[GSD](https://github.com/gsd-build/get-shit-done)** — spec-driven development system for Claude Code
- **General:** git, gh, ripgrep, fd, fzf, jq, delta, zsh

---

## Safety model

The sandbox protects your host by isolating the agent's actions inside a container. Each harness gets the equivalent of "yes to everything" — Claude with `--dangerously-skip-permissions`, Codex with `--dangerously-bypass-approvals-and-sandbox`, Pi running in its native permissionless mode — so the agent never stops to ask for approval. The Docker layer is what keeps that safe.

Think of it as: **full autonomy, bounded blast radius.**

### vs. Claude Code's built-in sandbox

Claude Code has its own `/sandbox` feature (using Apple Seatbelt on macOS, bubblewrap on Linux) that restricts bash commands to `$PWD` and proxies network traffic. `safebox` takes a different approach:

| | Built-in sandbox | safebox (Docker) |
|---|---|---|
| **Isolation scope** | Bash commands only | Entire OS environment |
| **Filesystem** | R/W to `$PWD`, read-only elsewhere | Only `$PWD` and the active harness's config dir |
| **Network** | Proxied, domain allowlist | Full access (or `--network none`) |
| **Overhead** | Lightweight, native | Full container startup |
| **Customizable env** | No | Yes — edit the Dockerfile |
| **Multi-harness** | Claude only | Claude, Codex, Pi |

The built-in sandbox is a good fit for interactive use on your own machine. `safebox` is better when you want a fully reproducible, customizable environment — or when you're running an agent autonomously and want stronger isolation guarantees.
