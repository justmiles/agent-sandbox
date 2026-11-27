# agent-sandbox

A container that runs a coding agent as a long-lived process. It starts the agent, keeps its home directory on a volume, and comes with the tools I use for development: Nix, Git, Go, Node.js, the GitHub CLI and more.

I run agents this way so they can work on their own in a place I can throw away, reach from anywhere, and rebuild from one Dockerfile. This repository shows how it's put together. Use it as is, or borrow the parts you need.

Pick the agent with `AGENT`. Every agent starts in `/home/sandbox/workspace`.

| `AGENT`            | Runs                                                                         |
| ------------------ | ---------------------------------------------------------------------------- |
| `claude` (default) | [Claude Code](https://code.claude.com/docs) Remote Control (`claude rc`)     |
| `opencode`         | [OpenCode](https://github.com/sst/opencode) server (`opencode serve`)        |
| `itsaplan`         | [`@itsaplan/runner`](https://www.npmjs.com/package/@itsaplan/runner)         |

The agent runs as the unprivileged `sandbox` user. There is no sudo. Read [Security](#security) before you give it Docker or Tailscale access. Either Docker mode gives the agent root on the host. Tailscale can give root in the container: Tailscale SSH is served as root to whoever your tailnet policy lets in, which may include the agent. It's on with `--ssh` in `TS_EXTRA_ARGS` or when left on in the saved Tailscale state, and `TS_OPERATOR=true` lets the agent turn it on.

How the startup works, file by file, is in [docs/how-it-works.md](docs/how-it-works.md). Docker setup and its risks are in [docs/docker.md](docs/docker.md).

## Quickstart

### Claude Code

```bash
docker run -d --name agent-sandbox --restart unless-stopped \
  -v agent-sandbox-home:/home/sandbox \
  ghcr.io/justmiles/agent-sandbox:latest
```

Remote Control needs you to be signed in with a claude.ai subscription. On the first start it isn't, so the container logs this and waits 5 minutes before it exits:

```
  Claude Remote Control exited. Authentication or workspace trust
  may be required.

  To authenticate, run:
    docker exec -it -u sandbox -e HOME=/home/sandbox <container> claude auth login
```

Sign in during that window:

```bash
docker exec -it -u sandbox -e HOME=/home/sandbox agent-sandbox claude auth login
```

The credentials are saved in the home volume. When the wait ends the container exits, and `--restart unless-stopped` starts it again, signed in this time. Run `docker restart agent-sandbox` if you don't want to wait.

If Claude Code then reports that the workspace isn't trusted, run it once in the workspace and accept the trust dialog:

```bash
docker exec -it -u sandbox -e HOME=/home/sandbox -w /home/sandbox/workspace agent-sandbox claude
```

Exit Claude Code after that and restart the container. The trust decision is saved in the home volume. This step hasn't been tested with a signed-in account. See [Security](#security) for the shipped trust file.

### OpenCode

```bash
docker run -d --name agent-sandbox-opencode \
  -e AGENT=opencode \
  -e OPENCODE_SERVER_PASSWORD=change-me \
  -p 127.0.0.1:8080:8080 \
  -v agent-sandbox-opencode-home:/home/sandbox \
  ghcr.io/justmiles/agent-sandbox:latest
```

OpenCode listens on `0.0.0.0:8080` inside the container. The example publishes it on the host's loopback address only. With `OPENCODE_SERVER_PASSWORD` set, OpenCode asks for HTTP basic auth; the username is `opencode` unless you set `OPENCODE_SERVER_USERNAME`. Without a password, anyone who can reach the port can drive the agent.

Connect with an OpenCode client:

```bash
opencode attach http://127.0.0.1:8080 --password change-me
```

The image ships my own OpenCode config, which expects an OpenAI-compatible gateway and a few MCP servers. Replace `~/.config/opencode/opencode.jsonc` with your own, or see [docs/how-it-works.md](docs/how-it-works.md#the-shipped-opencode-config) for what each entry needs.

### itsaplan

```bash
docker run -d --name agent-sandbox-itsaplan \
  -e AGENT=itsaplan \
  -v agent-sandbox-itsaplan-home:/home/sandbox \
  ghcr.io/justmiles/agent-sandbox:latest
```

This runs `npx -y @itsaplan/runner@latest` in `/home/sandbox/workspace`. Set `ITSAPLAN_RUNNER_VERSION` to pin a version. See the runner's own documentation for how it connects and signs in.

### Shell

Open a shell in a running container as the agent's user:

```bash
docker exec -it -u sandbox -e USER=sandbox agent-sandbox bash
```

`-e USER=sandbox` matters. Without it, `.bashrc` can't load the Nix profile, and Nix tools such as `gh` and `go` are missing. A non-interactive `docker exec -u sandbox` doesn't read `.bashrc` at all, so it has neither the Nix tools nor `~/bin` on its PATH. The agent itself gets both.

For a throwaway shell that starts nothing (no agent, no Tailscale, no `~/package.nix`, the image's own home directory):

```bash
docker run --rm -it -u sandbox -e USER=sandbox --entrypoint bash ghcr.io/justmiles/agent-sandbox:latest
```

Leave out `-u sandbox` and you get a root shell.

### Your own project

Mount a project at `/home/sandbox/workspace`. The `sandbox` user must be able to write to it, so set `SANDBOX_UID` and `SANDBOX_GID` to the owner of the directory if that isn't 1000. Changing them doesn't re-own the project's files: mounts under `/home/sandbox` are left alone (see [Persistence](#persistence)). On every start, the harness adds `.claude/settings.json` to the workspace if it's missing, so deleting it doesn't last (see [Security](#security)).

## Docker

The agent can have no Docker, the host's Docker, or its own Docker daemon.

| Mode                   | How to enable                                                              | Agent's reach                                  |
| ---------------------- | -------------------------------------------------------------------------- | ---------------------------------------------- |
| None (default)         | nothing                                                                    | unprivileged user inside the container         |
| Host socket            | mount `/var/run/docker.sock`; `SANDBOX_GIDS` for the socket's group        | root on the host                               |
| Docker-in-Docker       | `--privileged` and `DOCKER_DIND=true`                                      | effectively root on the host                   |

Host socket:

```bash
gid=$(docker run --rm -v /var/run/docker.sock:/s --entrypoint stat ghcr.io/justmiles/agent-sandbox:latest -c %g /s)
docker run -d --name agent-sandbox \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e SANDBOX_GIDS="$gid" \
  -v agent-sandbox-home:/home/sandbox \
  ghcr.io/justmiles/agent-sandbox:latest
```

The image's `docker` group has GID 997 and `sandbox` is in it. If the host socket's group is 997, the agent can use it without `SANDBOX_GIDS`.

Docker-in-Docker:

```bash
docker run -d --name agent-sandbox \
  --privileged --stop-timeout 30 \
  -e DOCKER_DIND=true \
  -v agent-sandbox-home:/home/sandbox \
  -v agent-sandbox-docker:/var/lib/docker \
  ghcr.io/justmiles/agent-sandbox:latest
```

The agent starts only once the inner daemon answers. `--stop-timeout 30` gives the daemon time to shut down: Docker's default is 10 seconds, and `dockerd` waits up to 15 seconds for its own containers. Without the `/var/lib/docker` volume the daemon falls back to the `vfs` storage driver, which is slow and uses a lot of disk.

Docker-in-Docker refuses to start next to a host socket, without `--privileged`, on cgroup v1, with the host's cgroup namespace, and on the host's network. [docs/docker.md](docs/docker.md) has the messages, the limits of those checks, and the risks.

## Tailscale

Tailscale joins the container to your tailnet, so you can reach the agent from your other devices. `tailscaled` always runs, in userspace networking mode by default. The harness brings the node up only when you give it an auth key:

```bash
docker run -d --name agent-sandbox \
  -e TS_AUTH_KEY=tskey-auth-XXXXXXXX \
  -e TS_HOSTNAME=my-agent \
  -v agent-sandbox-home:/home/sandbox \
  -v agent-sandbox-tailscale:/var/lib/tailscale \
  ghcr.io/justmiles/agent-sandbox:latest
```

Other devices can then reach the container's ports by its Tailscale name, for example OpenCode at `http://my-agent:8080`. Assume the agent can reach whatever your tailnet policy lets this node reach. In userspace mode, Tailscale offers a SOCKS5 or HTTP proxy for outgoing connections ([Tailscale docs](https://tailscale.com/kb/1112/userspace-networking)). The harness doesn't turn it on, but that isn't a barrier to rely on. Set `TS_USERSPACE=false` for kernel networking, which needs `--device /dev/net/tun --cap-add NET_ADMIN`.

`tailscaled` runs in every container, with or without `TS_AUTH_KEY`, and connects to Tailscale's log service (`log.tailscale.com`) even when the node never comes up.

The auth key is passed to `tailscale up` in a file that only root can read (and `sandbox`, with `TS_OPERATOR=true`), and the file is removed afterwards. A `TS_AUTH_KEY` that starts with `file:` is passed on as it is. If `tailscale up` fails, the log says `tailscale up failed`, the node stays down, and the agent starts anyway.

A common cause is this error:

```
Error: changing settings via 'tailscale up' requires mentioning all
non-default flags. To proceed, either re-run your command with --reset or
use the command below to explicitly mention the current value of
all non-default settings:
```

`tailscale up` refuses to run when a setting saved in the state isn't among its arguments. That happens when you remove `TS_HOSTNAME`, `TS_ROUTES` or `TS_ACCEPT_ROUTES`, or a flag from `TS_EXTRA_ARGS`, or when a setting was changed with `tailscale set`, for example Tailscale SSH. To fix it, either add the setting back, or change the saved setting as root and restart, for example `docker exec agent-sandbox tailscale set --ssh=false`. The harness doesn't pass `--reset`.

The variables are listed under [Environment variables](#environment-variables). `TS_ACCEPT_DNS` is not read; pass `--accept-dns=false` in `TS_EXTRA_ARGS` instead.

### Agent control of Tailscale

The agent has no control over Tailscale unless you set `TS_OPERATOR=true` (exactly `true`).

By default, root runs `tailscale up` and `tailscale down`. On every start, before any code the agent controls runs, root clears any operator saved in the Tailscale state and reads the result back. This happens with or without `TS_AUTH_KEY`. With Docker-in-Docker there's one exception: inner containers with a restart policy can start before that. If it can't be confirmed, for example because `tailscaled` doesn't start, the container stops with:

```
Cannot confirm that the sandbox user has no Tailscale control; not starting the agent
```

With `TS_OPERATOR=true`, `sandbox` becomes the Tailscale operator, with or without `TS_AUTH_KEY`, and runs `tailscale up` and `down` itself. The operator can change any of the node's settings. That includes:

- Turning on Tailscale SSH (`tailscale set --ssh`). `tailscaled` serves it as root, so your tailnet policy decides who may log in to the container, and as which user, root included.
- Making another user the operator (`tailscale set --operator=...`).
- Sharing local ports with the tailnet through `tailscale serve`, and with the internet through `tailscale funnel` if your tailnet policy allows Funnel. Serving files, directories or Unix sockets requires root ([Tailscale docs](https://tailscale.com/kb/1242/tailscale-serve)), so the operator can't use `serve` to read files as root.

Settings made while opted in stay in the state after you remove `TS_OPERATOR=true`. Only the operator is cleared. To undo the rest, run as root, for example `docker exec agent-sandbox tailscale set --ssh=false` and `docker exec agent-sandbox tailscale serve reset`.

Don't grant control with `TS_EXTRA_ARGS=--operator=sandbox`. Without `TS_OPERATOR=true` that gives the agent control while `~/package.nix` is being installed, and only after that is the agent's start refused.

`TS_OPERATOR` doesn't limit an agent that has Docker-in-Docker or the host's Docker socket. That agent is root on the host already.

## Environment variables

All are optional.

| Name                       | Default                          | Description |
| -------------------------- | -------------------------------- | ----------- |
| `AGENT`                    | `claude`                         | Agent to run: `claude`, `opencode` or `itsaplan`. Any other value stops the container with `Unknown AGENT: <value> (valid: claude, itsaplan, opencode)`. |
| `CLAUDE_RC_ARGS`           | empty                            | Extra arguments for `claude rc`, parsed with shell quoting. |
| `OPENCODE_ARGS`            | `--hostname 0.0.0.0 --port 8080` | Arguments for `opencode serve`. Split on spaces; quotes are not honoured. Setting it replaces the default, so include the host and port. |
| `OPENCODE_SERVER_PASSWORD` | empty (no auth)                  | Read by OpenCode. Turns on HTTP basic auth for the server. |
| `OPENCODE_SERVER_USERNAME` | `opencode`                       | Read by OpenCode. Username for basic auth. |
| `ITSAPLAN_RUNNER_VERSION`  | `latest`                         | npm version of `@itsaplan/runner` to run. |
| `SANDBOX_UID`              | `1000`                           | User ID of `sandbox`. An ID that isn't a number, or is taken by another user, is reported and ignored. |
| `SANDBOX_GID`              | `1000`                           | Group ID of `sandbox`, with the same checks. |
| `SANDBOX_GIDS`             | empty                            | Extra group IDs for `sandbox`, separated by commas or spaces. A group that doesn't exist is created as `sandbox-<gid>`. |
| `DOCKER_DIND`              | off                              | `true` (exactly) runs a Docker daemon inside the container. Needs `--privileged`. |
| `TS_AUTH_KEY`              | empty                            | Tailscale auth key. When set, `tailscale up` runs with it. The settings below that go to `tailscale up` apply only when this is set. |
| `TS_HOSTNAME`              | empty                            | `tailscale up --hostname`. |
| `TS_ACCEPT_ROUTES`         | off                              | `true` adds `--accept-routes` to `tailscale up`. |
| `TS_ROUTES`                | empty                            | `tailscale up --advertise-routes`, for example `10.0.0.0/24`. |
| `TS_EXTRA_ARGS`            | empty                            | More arguments for `tailscale up`. |
| `TS_STATE_DIR`             | empty                            | `tailscaled --statedir`. Without it and `TS_STATE`, state goes to `/var/lib/tailscale`. |
| `TS_STATE`                 | empty                            | `tailscaled --state`. |
| `TS_USERSPACE`             | `true`                           | `true` runs `tailscaled --tun=userspace-networking`. Any other value uses kernel networking. |
| `TS_OPERATOR`              | off                              | `true` (exactly) makes `sandbox` the Tailscale operator. See [Agent control of Tailscale](#agent-control-of-tailscale). |
| `AGENTGATEWAY_BASE_URL`    | empty                            | Used by the shipped OpenCode config: base URL of an OpenAI-compatible API. |
| `AGENTGATEWAY_API_KEY`     | empty                            | Used by the shipped OpenCode config: API key for that endpoint. |
| `AGENTGATEWAY_MODEL_NAME`  | empty                            | Used by the shipped OpenCode config: display name of its one model. |
| `S6_*`                     | see below                        | [s6-overlay settings](https://github.com/just-containers/s6-overlay#customizing-s6-behaviour). |

The image also sets `S6_VERBOSITY=0`, `S6_CMD_WAIT_FOR_SERVICES_MAXTIME=300000` (startup services get 5 minutes), `CLAUDE_CODE_VERSION` (the preinstalled release) and `DISABLE_UPDATES=1`, which keeps Claude Code from updating itself. A new version comes with a new image.

## Volumes

| Path                   | Holds |
| ---------------------- | ----- |
| `/home/sandbox`        | The home directory: agent credentials and config, `~/workspace`, `~/package.nix`, shell history, SSH keys. |
| `/var/lib/tailscale`   | The Tailscale node's identity and settings. Without it, every new container joins as a new node. |
| `/var/lib/docker`      | Docker-in-Docker images, containers and volumes. Also keeps the daemon off the slow `vfs` driver. |
| `/var/run/docker.sock` | The host's Docker socket, for host socket mode. |

Never put a state volume inside the home volume, such as Tailscale state under `/home/sandbox`. The agent can change anything in its home directory, including the directory a volume is mounted on at the next start. If `TS_STATE_DIR` or `TS_STATE` points under `/home/sandbox` or `/nix`, the container logs `WARNING: Tailscale state path <path> is writable by the sandbox user` and carries on.

## Persistence

The home volume keeps everything under `/home/sandbox`. On every start, files from the image's home directory that are missing are copied in. Files that exist are left alone, so your edits stay. A default file you delete comes back at the next start, so edit it instead.

The Nix profile is the exception. It's reset to the image's profile on every start, so packages installed with `nix-env -i` are gone after a restart. List them in `~/package.nix` instead, and they're installed on every start:

```nix
with import <nixpkgs> {};
buildEnv {
  name = "user-packages";
  paths = [
    htop
    ripgrep
  ];
}
```

The install runs before the agent starts, and its output appears in the container log with a `[nix-packages]` prefix. If it fails, it's retried once with a clean profile. If that fails too, the agent starts anyway, without those packages. `/nix` is not a volume, so a new container downloads or builds these packages again, and needs network access for it; a restart of the same container doesn't.

Packages from `~/package.nix` come first on the agent's PATH. Listing `claude-code` there overrides the preinstalled, pinned Claude Code. It's an unfree package, so it needs `import <nixpkgs> { config.allowUnfree = true; }`.

After a change of `SANDBOX_UID` or `SANDBOX_GID`, files in the home directory that the old IDs owned are re-owned. Files of other owners, such as root, are left alone. So are other mounts under `/home/sandbox`, such as a project at `~/workspace`: they may be host directories. Fix their owners yourself if needed. In `/nix`, only directories are re-owned, so store files keep the old owner. They're read-only either way.

## Security

The agent runs as `sandbox`, with no sudo. Root runs the startup services, with a fixed PATH, and doesn't run anything the agent can write, such as files under `/home/sandbox` or `/nix`. That keeps the agent from becoming root inside the container only while it has no Docker access and no way in through Tailscale SSH. With either Docker mode it is root on the host anyway. Tailscale SSH is served as root, so it is a way to root in the container whenever it's on and your tailnet policy lets the agent log in as root: with `TS_OPERATOR=true` the agent can turn it on, `--ssh` in `TS_EXTRA_ARGS` turns it on, and a setting saved in the state keeps it on.

- **Host socket.** Access to the Docker socket is root on the host: the agent can start a container that mounts the host's filesystem. If the socket's group is 997, mounting it is enough; no `SANDBOX_GIDS` is needed.
- **Docker-in-Docker.** `--privileged` gives the container the host's devices and nearly all kernel capabilities, and an inner `--privileged` container gets the same. Treat it as root on the host. The details are in [docs/docker.md](docs/docker.md).
- **Environment variables.** The agent inherits the container's environment, including `TS_AUTH_KEY`, `AGENTGATEWAY_API_KEY` and `OPENCODE_SERVER_PASSWORD`. Only pass in keys you're fine with the agent reading. With a reusable Tailscale key, the agent could add nodes of its own to your tailnet. A single-use key is a good fit.
- **OpenCode has no password by default.** Anyone who can reach port 8080 can run commands as the agent. That includes other containers on the same Docker network and, with Tailscale, devices your tailnet policy lets in. Set `OPENCODE_SERVER_PASSWORD` and publish the port on `127.0.0.1` only.
- **Unpinned downloads.** The shipped OpenCode config runs `npx -y @playwright/mcp@latest` and `npx -y @modelcontextprotocol/server-sequential-thinking`. `AGENT=itsaplan` runs `npx -y @itsaplan/runner@latest` unless `ITSAPLAN_RUNNER_VERSION` pins it. These run whatever npm serves at the time. Pin versions if that matters to you.
- **Workspace trust file.** The image ships `~/workspace/.claude/settings.json` containing `"hasTrustDialogAccepted": true`. It was meant to mark the workspace as trusted, but it hasn't been verified to skip Claude Code's trust prompt, and it probably doesn't: Claude Code keeps trust decisions per project in `~/.claude.json` ([Claude Code docs](https://code.claude.com/docs/en/settings)). The file is copied back on every start if it's missing, also into a project you mount at `~/workspace`, so replace its contents (for example with `{}`) rather than deleting it. If Claude Code reports that the workspace isn't trusted, its own message suggests two fixes, neither tested here: run Claude Code interactively in the workspace once and accept the trust dialog, for example with `docker exec -it -u sandbox -e HOME=/home/sandbox -w /home/sandbox/workspace agent-sandbox claude`, or set `projects["/home/sandbox/workspace"].hasTrustDialogAccepted` to `true` in `~/.claude.json`. Either way, the trust decision is saved in the home volume.
- **Tailscale.** Joining the tailnet exposes every port in the container to the devices your tailnet policy allows. Assume the agent can reach whatever your tailnet policy lets the node reach. Without `TS_OPERATOR=true`, any saved operator is cleared before code the agent controls runs, except inner Docker-in-Docker containers with a restart policy, which can start first. `TS_OPERATOR=true` gives the agent control of the node, including Tailscale SSH served as root. Settings made then stay in the state. Keep the state volume outside the home volume. See [Tailscale](#tailscale).

## Build and test

```bash
docker build -t agent-sandbox:dev .
test/smoke.sh agent-sandbox:dev
```

`test/smoke.sh IMAGE [FILTER]` runs every test whose name contains `FILTER`. Tests that need a privileged container or the host's Docker socket are skipped unless you set `SMOKE_PRIVILEGED=1` or `SMOKE_SOCKET=1`. CI runs the whole suite with both and publishes the image only if it passes. `just build` and `just test` do the same for `ghcr.io/justmiles/agent-sandbox:latest`.

## Licensing

The code in this repository is under the [MIT license](LICENSE). That covers only this repository's code.

The image includes other software under its own terms. Claude Code is preinstalled, unmodified, from Anthropic's official release, and is subject to [Anthropic's terms](https://code.claude.com/docs/en/legal-and-compliance). This project is not affiliated with Anthropic. You sign in with your own credentials.
