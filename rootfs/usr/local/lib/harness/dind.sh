# Docker-in-Docker helpers, sourced by the dockerd service and start.sh, both
# of which run as root.

# dind_enabled: true only when DOCKER_DIND is exactly "true".
dind_enabled() { [ "${DOCKER_DIND:-}" = true ]; }

# dind_cgroupns_private [FILE]: true when FILE (default /proc/1/cgroup) shows
# that PID 1 is at the root of its own cgroup v2 namespace: "0::/", or
# "0::/init" once dind_nest_cgroups has moved it. In the host's cgroup
# namespace, nesting would move the host's own processes.
dind_cgroupns_private() {
  local line
  line=$(cat -- "${1:-/proc/1/cgroup}" 2>/dev/null) || return 1
  [ "$line" = 0::/ ] || [ "$line" = 0::/init ]
}

# This container run's identity: the boot, PID 1's start time and the network
# namespace. A marker holding it says this run's own dockerd may have made the
# docker0 link, DOCKER chains and mounts under /run/docker that the checks
# below would otherwise take for the host's. `docker restart` starts a new PID
# 1, so each run is checked afresh.
DIND_MARKER=/run/harness/dind-checked
dind_run_id() {
  printf '%s %s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" \
    "$(sed 's/.*) //' /proc/1/stat | cut -d' ' -f20)" "$(readlink /proc/self/ns/net)"
}
dind_marked() { [ "$(cat "$DIND_MARKER" 2>/dev/null)" = "$(dind_run_id)" ]; }
# dind_mark: record that this run passed dind_check. Call before dockerd starts.
dind_mark() { mkdir -p "${DIND_MARKER%/*}" && dind_run_id >"$DIND_MARKER"; }

# dind_host_run_mounted: true when the host's socket, or its /run, or a
# directory of the host's daemon state may be mounted: a mount at /run,
# /run/docker.sock, /run/docker or /run/containerd, or, before this run's own
# dockerd has started, any mount under the last two.
dind_host_run_mounted() {
  local under=1
  dind_marked && under=0
  awk -v under="$under" '
    $5 ~ "^/(var/)?run(/docker\\.sock|/docker|/containerd)?$" { found = 1 }
    under && $5 ~ "^/(var/)?run/(docker|containerd)/" { found = 1 }
    END { exit !found }' /proc/self/mountinfo
}

# dind_host_network: true when, before this run's own dockerd has started, the
# network namespace already has a docker0 link or a DOCKER chain, as the
# host's does. A private namespace starts with neither. Legacy iptables is
# only asked when it has tables here, so listing never loads a module.
dind_host_network() {
  local t
  dind_marked && return 1
  [ -e /sys/class/net/docker0 ] && return 0
  for t in filter nat; do
    iptables -t "$t" -n -L DOCKER >/dev/null 2>&1 && return 0
    grep -qx "$t" /proc/net/ip_tables_names 2>/dev/null &&
      iptables-legacy -t "$t" -n -L DOCKER >/dev/null 2>&1 && return 0
  done
  return 1
}

# dind_check [CGROUP_FILE]: return 0 if dockerd may start, or print why not to
# stderr and return 1. CGROUP_FILE is passed to dind_cgroupns_private. It
# changes nothing, so it must pass before dockerd/run touches /run or iptables.
dind_check() {
  local capeff
  if dind_host_run_mounted; then
    echo "DOCKER_DIND=true conflicts with a host socket mounted at /var/run/docker.sock: remove one of them" >&2
    return 1
  fi
  capeff=$(awk '$1 == "CapEff:" { print $2 }' /proc/self/status)
  if (((0x${capeff:-0} >> 21 & 1) == 0)) || [ ! -w /sys/fs/cgroup ]; then
    echo "DOCKER_DIND=true needs a privileged container: run with --privileged" >&2
    return 1
  fi
  if ! dind_cgroupns_private "${1:-/proc/1/cgroup}"; then
    echo "DOCKER_DIND=true needs cgroup v2 and a private cgroup namespace: run with --cgroupns=private" >&2
    return 1
  fi
  if dind_host_network; then
    echo "DOCKER_DIND=true cannot share the host's network: remove --network=host" >&2
    return 1
  fi
}

# dind_nest_cgroups: move every process into a child cgroup, so that the
# container's root cgroup can delegate controllers to dockerd. Call only after
# dind_check succeeds. Retried because s6 may be spawning processes meanwhile.
dind_nest_cgroups() {
  local attempt
  dind_cgroupns_private || return 1
  [ -f /sys/fs/cgroup/cgroup.controllers ] || return 0
  mkdir -p /sys/fs/cgroup/init
  for attempt in $(seq 50); do
    xargs -rn1 </sys/fs/cgroup/cgroup.procs >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null || :
    sed -e 's/ / +/g' -e 's/^/+/' /sys/fs/cgroup/cgroup.controllers \
      >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null && return 0
    sleep 0.1
  done
  echo "dockerd: could not enable cgroup controllers for nesting" >&2
  return 1
}
