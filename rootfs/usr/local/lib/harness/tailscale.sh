# Tailscale helpers, sourced by the tailscale services and start.sh, all of
# which run as root.
#
# Tailscale's operator may change tailscaled's preferences, which includes
# turning on Tailscale SSH served by root and naming another operator. So the
# sandbox user is the operator only when TS_OPERATOR=true; otherwise the
# tailscale-revoke service clears any operator saved in the state before the
# first sandbox process starts.

TS_NO_CONTROL_MSG="Cannot confirm that the sandbox user has no Tailscale control; not starting the agent"

# ts_operator_enabled: true only when TS_OPERATOR is exactly "true".
ts_operator_enabled() { [ "${TS_OPERATOR:-}" = true ]; }

# ts_no_operator: true when tailscaled answers and its preferences name no
# operator.
ts_no_operator() {
  timeout -s KILL 10 tailscale debug prefs 2>/dev/null |
    jq -e 'type == "object" and (.OperatorUser // "") == ""' >/dev/null
}

# ts_clear_operator: clear the operator and read the result back.
ts_clear_operator() {
  timeout -s KILL 10 tailscale set --operator= >/dev/null 2>&1 && ts_no_operator
}

# ts_retry SECS CMD...: run CMD until it succeeds, for up to SECS seconds, as
# tailscaled may still be starting.
ts_retry() {
  local deadline=$(($(date +%s) + $1))
  shift
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 1
  done
}
