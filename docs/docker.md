# Docker

The agent can use Docker in one of two ways: the host's daemon through its socket, or a daemon of its own inside the container. Both give the agent root on the host. Running the agent as an unprivileged user without sudo doesn't change that, so only use these modes where you'd be fine with the agent having root on the host.

| Mode                   | How to enable                                                              | Agent's reach                                  |
| ---------------------- | -------------------------------------------------------------------------- | ---------------------------------------------- |
| None (default)         | nothing                                                                    | unprivileged user inside the container         |
| Host socket            | mount `/var/run/docker.sock`; `SANDBOX_GIDS` for the socket's group        | root on the host                               |
| Docker-in-Docker       | `--privileged` and `DOCKER_DIND=true`                                      | effectively root on the host                   |

The `docker` CLI with the `compose` and `buildx` plugins is installed in every mode. Without a socket or `DOCKER_DIND=true` it has nothing to talk to.

## Host socket

```bash
gid=$(docker run --rm -v /var/run/docker.sock:/s --entrypoint stat ghcr.io/justmiles/agent-sandbox:latest -c %g /s)
docker run -d --name agent-sandbox \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e SANDBOX_GIDS="$gid" \
  -v agent-sandbox-home:/home/sandbox \
  ghcr.io/justmiles/agent-sandbox:latest
```

The first line reads the socket's group as the container sees it. `SANDBOX_GIDS` adds `sandbox` to that group, creating it as `sandbox-<gid>` if needed.

The image's `docker` group has GID 997, and `sandbox` is a member. If the socket's group is 997, mounting the socket is all it takes: the agent can use it without `SANDBOX_GIDS`.

**Risk.** Whoever can use the socket controls the host's Docker daemon, which runs as root. The agent can start a privileged container, or one that mounts `/` from the host, and from there do anything root can. It can also see, stop and change every other container on the host.

Don't set `DOCKER_DIND=true` with a socket mounted. The container refuses to start.

## Docker-in-Docker

```bash
docker run -d --name agent-sandbox \
  --privileged --stop-timeout 30 \
  -e DOCKER_DIND=true \
  -v agent-sandbox-home:/home/sandbox \
  -v agent-sandbox-docker:/var/lib/docker \
  ghcr.io/justmiles/agent-sandbox:latest
```

The `dockerd` service starts the daemon as root, and the agent starts once `sandbox` can reach it, after up to 60 seconds. The daemon logs to the container's output with a `[dockerd]` prefix and to `/var/log/dockerd/current`.

Requirements:

- `--privileged`.
- A cgroup v2 host and a private cgroup namespace. Docker uses a private one by default on cgroup v2; pass `--cgroupns=private` if yours doesn't. cgroup v1 hosts are refused.
- The container's own network namespace, not the host's.
- Nothing mounted at `/run` or `/var/run`, or at the places the inner daemon keeps its state there.

**Use a volume at `/var/lib/docker`.** Overlay mounts can't be stacked on the container's own overlay filesystem. Without a volume the daemon uses the `vfs` storage driver, which copies every image layer in full: slow, and heavy on disk. Set `"storage-driver"` in `/etc/docker/daemon.json` to choose a driver yourself.

**Use a longer stop timeout.** `docker stop` waits 10 seconds by default before it kills the container, and `dockerd` gives its own containers up to 15 seconds to stop. Use `--stop-timeout 30` on `docker run`, or `docker stop -t 30`. A clean stop logs `Daemon shutdown complete`.

### Risks

- **Effectively root on the host.** A privileged container has nearly all kernel capabilities and the host's devices. The agent can start an inner `--privileged` container, which gets the host's devices too, and mount the host's disks from there.
- **AppArmor.** On a host with AppArmor enabled, the inner daemon may load or replace an AppArmor profile in the host's kernel. This is untested.
- **Shared limits.** Root in the container is root on the host, so per-user kernel limits are shared with the host's root, such as the inotify instance limit (`fs.inotify.max_user_instances`). The inner daemon uses more of them and can starve processes on the host.
- **Startup order.** The daemon starts alongside the other startup services, not after them. Inner containers with a restart policy, saved in the `/var/lib/docker` volume, can start before the Tailscale operator is cleared and before `start.sh` runs its checks. `TS_OPERATOR` doesn't limit an agent with Docker access in any case.

### Failure messages

Each of these stops the container with exit code 1 before the agent starts.

| Message | Cause |
| ------- | ----- |
| `DOCKER_DIND=true conflicts with a host socket mounted at /var/run/docker.sock: remove one of them` | Something is mounted at `/run`, `/var/run`, `/run/docker.sock`, `/run/docker` or `/run/containerd`, or under the last two before this run's daemon started. `--tmpfs /run` also gets this message, though no socket is involved. |
| `DOCKER_DIND=true needs a privileged container: run with --privileged` | The container lacks `CAP_SYS_ADMIN` or can't write to `/sys/fs/cgroup`. |
| `DOCKER_DIND=true needs cgroup v2 and a private cgroup namespace: run with --cgroupns=private` | The host uses cgroup v1, or the container shares the host's cgroup namespace. |
| `DOCKER_DIND=true cannot share the host's network: remove --network=host` | The network namespace already had a `docker0` link or a `DOCKER` iptables chain before this run's daemon started. |
| `Docker daemon did not become ready within 60s; see /var/log/dockerd` | The daemon didn't answer in time, for example because `/etc/docker/daemon.json` is invalid. |

`dockerd: could not enable cgroup controllers for nesting` can appear in the log before the last message.

### What the checks miss

The checks protect against common mistakes. They aren't a security boundary, and some setups slip past them or are refused wrongly:

- `--pid=host` and `--ipc=host` aren't detected.
- The host network is recognised only by Docker's `docker0` link or `DOCKER` chains. A host without them, or one running Podman, isn't detected.
- Restarting a container whose network namespace outlives it is wrongly refused with the host-network message, because the namespace still holds the previous run's `docker0`. This happens with Nomad's bridge mode, Kubernetes pods and `--network=container:`. Start a new group or pod, so the network namespace is new too.

### cgroups

`dockerd` needs to hand cgroup controllers to its containers. cgroup v2 doesn't allow that from a cgroup that has processes of its own, so the `dockerd` service first moves every process in the container into a child cgroup, `/init`, then turns on all controllers for the container's root cgroup.

That move is done only when PID 1 sits at the root of a private cgroup namespace (`/proc/1/cgroup` reads `0::/`, or `0::/init` after the move). In the host's namespace it would move the host's own processes, so the container is refused instead.

### iptables

The inner daemon sets up its own iptables rules, in the container's network namespace. Ubuntu's default `iptables` uses nf_tables. When that doesn't work on the host's kernel and legacy iptables does, the service links `iptables` and `ip6tables` in `/usr/local/sbin` to the legacy versions before it starts the daemon.
