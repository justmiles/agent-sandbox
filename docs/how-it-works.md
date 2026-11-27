# How it works

The image is Ubuntu 22.04 with [s6-overlay](https://github.com/just-containers/s6-overlay) as PID 1. s6 starts a few services as root, then runs `start.sh`, which hands over to one agent launcher as the `sandbox` user. Everything the image adds to the filesystem is under `rootfs/` and `home/`, laid out where it ends up.

## Boot order

1. **`/init`** (s6-overlay, root) starts the services in the `user` bundle, in dependency order. `S6_CMD_WAIT_FOR_SERVICES_MAXTIME=300000` gives them 5 minutes.
2. **`tailscaled`** (long-running, root) starts `tailscaled`. It warns if `TS_STATE_DIR` or `TS_STATE` points under `/home/sandbox` or `/nix`.
3. **`dockerd`** (long-running, root) has no dependencies, so it starts alongside the rest. Unless `DOCKER_DIND=true` and the Docker-in-Docker checks pass, it just idles and runs nothing. See [docker.md](docker.md).
4. **`tailscale-revoke`** (oneshot, root, after `tailscaled`) clears any Tailscale operator saved in the state, unless `TS_OPERATOR=true`, and reads it back. It gives up after 60 seconds. When it fails, s6 starts none of the services below.
5. **`init-home`** (oneshot, after `tailscale-revoke`) sets the user and group IDs and fixes ownership as root, then fills the home directory as `sandbox`.
6. **`nix-packages`** (oneshot, after `init-home` and `tailscale-revoke`) installs `~/package.nix` as `sandbox`.
7. **`tailscale`** (oneshot, after `tailscaled`, `tailscale-revoke` and `init-home`) makes `sandbox` the operator if `TS_OPERATOR=true`, then runs `tailscale up` if `TS_AUTH_KEY` is set, passing the key in a file under `/run/harness` that it removes afterwards. When the container stops, it runs `tailscale down`.
8. **`start.sh`** (root) runs once the services are up. In order, it:
   - refuses to go on, unless `TS_OPERATOR=true`, if `tailscale-revoke` didn't succeed in this run or `tailscaled` now reports an operator;
   - adds the `SANDBOX_GIDS` groups;
   - with `DOCKER_DIND=true`, repeats the Docker-in-Docker checks and waits up to 60 seconds until `sandbox` can reach the daemon;
   - checks `AGENT`, logs `Starting agent: <name>`, and replaces itself with `/usr/local/lib/agents/<name>.sh`, run as `sandbox`.

On `docker stop`, s6 stops the agent first, then the services in reverse order.

Each service logs to the container's output with its name as a prefix, such as `[init-home]`, and to `/var/log/<service>/current`. `tailscale-revoke` is the exception: it logs as `[tailscale]`, to `/var/log/tailscale/current`.

## What runs as root

| Process | Runs as | Why |
| ------- | ------- | --- |
| s6 and the service scripts | root | PID 1 and service supervision. |
| `tailscaled` | root | Tailscale's daemon. |
| `tailscale-revoke` | root | Clears the operator. |
| `init-home` | root, then `sandbox` | Root changes IDs and ownership only; `sandbox` copies files. |
| `nix-packages` | `sandbox` | Root only starts it. |
| `tailscale up` and `down` | root, or `sandbox` with `TS_OPERATOR=true` | |
| `dockerd` | root | Only with `DOCKER_DIND=true`. |
| `start.sh` | root, until it starts the agent | Groups and checks. |
| The agent | `sandbox` | |

Every root script first sources `root-env.sh`, which sets a fixed PATH without `/home/sandbox` or `/nix`. `sandbox` owns both of those, so root never runs a program from them. Root also doesn't copy, create or delete files under the home directory. It only changes ownership, without following symlinks, and only of files the previous IDs owned.

None of this contains an agent that has Docker access. See [docker.md](docker.md).

## Files

| Path | Job |
| ---- | --- |
| `Dockerfile` | Installs apt packages, Tailscale, Nix and the Nix toolset, s6-overlay, OpenCode and Claude Code. Copies `home/` into the home directory and `rootfs/` to `/`, then makes the root-owned skeleton `/home_skel`. |
| `rootfs/usr/local/bin/start.sh` | Shared setup before the agent, as described above. |
| `rootfs/usr/local/lib/agents/claude.sh` | Runs `claude rc $CLAUDE_RC_ARGS` in `~/workspace` under `script`, which gives it a terminal. If it fails, prints the login and trust hint and waits 5 minutes before exiting. |
| `rootfs/usr/local/lib/agents/opencode.sh` | Runs `opencode serve $OPENCODE_ARGS`. |
| `rootfs/usr/local/lib/agents/itsaplan.sh` | Runs `npx -y @itsaplan/runner@$ITSAPLAN_RUNNER_VERSION` in `~/workspace`. |
| `rootfs/usr/local/lib/harness/root-env.sh` | Root's fixed PATH. |
| `rootfs/usr/local/lib/harness/tailscale.sh` | Helpers to check and clear the Tailscale operator. |
| `rootfs/usr/local/lib/harness/dind.sh` | Docker-in-Docker checks and cgroup setup. |
| `rootfs/etc/s6-overlay/s6-rc.d/` | One directory per service. `user/contents.d/` lists the services that start. A `dependencies` file or `dependencies.d/` directory sets the order. |
| `.../init-home/scripts/run.sh` | Root part of `init-home`: applies `SANDBOX_UID` and `SANDBOX_GID`, re-owns the old IDs' files in `/home/sandbox`, except on mounts under it, and the directories of `/nix`. |
| `.../init-home/scripts/populate.sh` | `sandbox` part: copies missing files from `/home_skel` and resets the Nix profile links to the image's. |
| `.../nix-packages/scripts/run.sh` | `nix-env -i -f ~/package.nix`, retried once with a clean profile. |
| `.../tailscaled/run` | Builds the `tailscaled` arguments from `TS_STATE_DIR`, `TS_STATE` and `TS_USERSPACE`. |
| `.../tailscale/scripts/tailscale.sh` | `revoke`, `up` and `down` for the `tailscale-revoke` and `tailscale` services. |
| `.../dockerd/run` | Starts `dockerd` for Docker-in-Docker. |
| `home/` | The default home directory: `.bashrc`, Nix config, the OpenCode config, the `package.nix` template and `workspace/.claude/settings.json`. |
| `test/smoke.sh` | Starts the image in each mode and checks the behaviour above. |
| `.github/workflows/docker.yml` | Builds, runs the smoke test, and pushes the tested image. |
| `renovate.json` | Keeps the pinned OpenCode, s6-overlay and Claude Code versions current. |
| `justfile` | `build`, `push`, `test`, `run` and `run-shell` recipes. |

The agent's PATH is `~/.nix-profile/bin`, then the image's PATH, then `~/bin`.

## Adding an agent

1. Install it in the `Dockerfile`, root-owned, on the system PATH. Pin the version with an `ENV` line that Renovate can track.
2. Add `rootfs/usr/local/lib/agents/<name>.sh`. It runs as `sandbox` with `HOME=/home/sandbox`, so it should only change to `/home/sandbox/workspace` and `exec` the agent. Make it executable.
3. Add `<name>` to both the `case` and the message in `start.sh`.
4. Add a test to `test/smoke.sh` that starts it without credentials and checks how far it gets.
5. Document it in the README: the `AGENT` table, a quickstart and its variables.

## The shipped OpenCode config

`home/.config/opencode/opencode.jsonc` is my own setup, included as an example. It's copied to `~/.config/opencode/opencode.jsonc` on every start if that file is missing. An existing file is left alone, so edit or replace it in the home volume. A deleted one comes back at the next start.

| Entry | Type | What it needs |
| ----- | ---- | ------------- |
| `agentgateway` provider | OpenAI-compatible API through `@ai-sdk/openai-compatible` | `AGENTGATEWAY_BASE_URL` and `AGENTGATEWAY_API_KEY`. `AGENTGATEWAY_MODEL_NAME` is the display name of its one model. The model ID, `cli-proxy-api/claude-sonnet-5`, is a key in the file. Variable substitution is only reliable in values, so change the ID in the file. |
| `playwright` MCP server | local, `npx -y @playwright/mcp@latest --headless --no-sandbox` | Downloaded from npm when OpenCode starts it. The image includes no browser for it. |
| `context7` MCP server | remote, `https://mcp.context7.com/mcp` | Network access. |
| `sequential-thinking` MCP server | local, `npx -y @modelcontextprotocol/server-sequential-thinking` | Downloaded from npm when OpenCode starts it. |
| `linear` MCP server | remote, `https://mcp.linear.app/mcp` | A Linear account. Sign in with `opencode mcp auth linear`. |

OpenCode's built-in providers work too: sign in with `opencode auth login` as `sandbox`, and the credentials are kept in the home volume.
