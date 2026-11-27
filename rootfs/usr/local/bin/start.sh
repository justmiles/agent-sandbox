#!/command/with-contenv bash

set -euo pipefail

exec 2>&1

# The agent's PATH: the Nix profile first, ~/bin last. Root uses a fixed PATH.
AGENT_PATH=/home/sandbox/.nix-profile/bin:$PATH:/home/sandbox/bin
. /usr/local/lib/harness/root-env.sh

# Unless TS_OPERATOR=true, the sandbox user must have no Tailscale control:
# tailscale-revoke must have succeeded in this run (s6 still runs this script
# when it failed), and tailscaled must still report no operator.
. /usr/local/lib/harness/tailscale.sh
if ! ts_operator_enabled; then
  if ! s6-rc -a list | grep -x tailscale-revoke >/dev/null || ! ts_retry 10 ts_no_operator; then
    echo "$TS_NO_CONTROL_MSG"
    exit 1
  fi
fi

# Support additional custom groups
CUSTOMGROUPS="${SANDBOX_GIDS:-}"; CUSTOMGROUPS="${CUSTOMGROUPS//,/ }"
for gid in $CUSTOMGROUPS; do
  if ! getent group "${gid}" >/dev/null 2>&1; then
    groupadd -g "${gid}" "sandbox-${gid}"
  fi
  usermod -a -G "${gid}" sandbox
done

# Docker-in-Docker: the dockerd service started the daemon if dind_check
# passed; the agent starts only once the sandbox user can reach it.
. /usr/local/lib/harness/dind.sh
if dind_enabled; then
  dind_check || exit 1
  deadline=$((SECONDS + 60))
  until timeout -s KILL 10 s6-setuidgid sandbox env HOME=/home/sandbox \
    docker -H unix:///var/run/docker.sock info >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      echo "Docker daemon did not become ready within 60s; see /var/log/dockerd"
      exit 1
    fi
    sleep 1
  done
fi

AGENT="${AGENT:-claude}"

case "$AGENT" in
  claude | itsaplan | opencode) ;;
  *)
    echo "Unknown AGENT: $AGENT (valid: claude, itsaplan, opencode)"
    exit 1
    ;;
esac

echo "Starting agent: $AGENT"
exec s6-setuidgid sandbox env HOME=/home/sandbox PATH="$AGENT_PATH" "/usr/local/lib/agents/$AGENT.sh"
