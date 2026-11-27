#!/command/with-contenv bash

. /usr/local/lib/harness/root-env.sh
. /usr/local/lib/harness/tailscale.sh

# revoke (the tailscale-revoke service): unless TS_OPERATOR=true, clear any
# operator that tailscaled restored from its state, and read it back. Every
# service that starts a sandbox process depends on it, so s6 starts none of
# them when this fails, and start.sh then refuses to start the agent.
revoke () {
  ts_operator_enabled && return 0
  ts_retry 60 ts_clear_operator && return 0
  echo "Could not clear the Tailscale operator within 60s; see /var/log/tailscaled"
  return 1
}

# The sandbox user runs `tailscale up` and `down` only as the operator.
as_ts_user () {
  if ts_operator_enabled; then
    USER=sandbox HOME=/home/sandbox s6-setuidgid sandbox "$@"
  else
    "$@"
  fi
}

# The auth key goes to `tailscale up` in a file, so that the command line it
# prints on an error does not show the key. Only root can read the file, or
# also the sandbox group when sandbox runs `tailscale up` as the operator.
# /run/harness is root's, so the sandbox user cannot plant or swap it.
TS_KEY_FILE=/run/harness/tailscale-auth-key

write_key_file () {
  mkdir -p "${TS_KEY_FILE%/*}" &&
    (umask 077 && set -o noclobber && printf '%s' "$TS_AUTH_KEY" >"$TS_KEY_FILE") || return 1
  if ts_operator_enabled; then
    chgrp sandbox "$TS_KEY_FILE" && chmod 0640 "$TS_KEY_FILE"
  fi
}

up () {
  local ARGS='' key rc
  rm -f "$TS_KEY_FILE"

  if ts_operator_enabled; then
    ts_retry 60 tailscale set --operator=sandbox 2>/dev/null || echo "Could not make sandbox the Tailscale operator"
  fi

  # only start tailscale if it's enabled
  [ -z "${TS_AUTH_KEY}" ] && exit 0

  # A key that is already a file: path is passed on as it is.
  key=$TS_AUTH_KEY
  if [[ $key != file:* ]]; then
    if ! write_key_file; then
      rm -f "$TS_KEY_FILE"
      echo "tailscale up not run: could not write the auth key to $TS_KEY_FILE"
      return 1
    fi
    key=file:$TS_KEY_FILE
  fi

  [ "${TS_ACCEPT_ROUTES}" = "true" ]  && ARGS="--accept-routes ${ARGS}"
  ARGS="--auth-key=${key} ${ARGS}"
  [ ! -z "${TS_HOSTNAME}" ]           && ARGS="--hostname=${TS_HOSTNAME} ${ARGS}"
  [ ! -z "${TS_ROUTES}" ]             && ARGS="--advertise-routes=${TS_ROUTES} ${ARGS}"
  [ ! -z "${TS_EXTRA_ARGS}" ]         && ARGS="${TS_EXTRA_ARGS} ${ARGS}"

  rc=0
  as_ts_user tailscale up ${ARGS} 2>&1 || rc=$?
  rm -f "$TS_KEY_FILE"
  if [ "$rc" != 0 ]; then
    echo "tailscale up failed (exit $rc), so the node is not connected; the agent starts anyway"
    return "$rc"
  fi
}

down () {
  as_ts_user tailscale down
}

# execute the passed in argument
"$1" 2>&1 | s6-log -bp n3 'p[tailscale]' 1 /var/log/tailscale
rc=${PIPESTATUS[0]}
# Only revoke's result is passed on to s6: the others never stopped a start.
[ "$1" != revoke ] || exit "$rc"
