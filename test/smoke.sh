#!/usr/bin/env bash
# Smoke test for a built image.
#
#   test/smoke.sh IMAGE [FILTER]
#
# Runs every test_* function whose name contains FILTER. Works against a remote
# or sibling Docker daemon: no bind mounts of local files, no published ports.
# Removes only the containers and volumes it created.

set -euo pipefail

[ $# -ge 1 ] || { echo "usage: $0 IMAGE [FILTER]" >&2; exit 2; }
IMAGE=$1
FILTER=${2:-}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Names are unique per run; the label marks everything this run created.
PREFIX="smoke-$$-$RANDOM"
LABEL="agent-sandbox.smoke=$PREFIX"

# --- helpers -----------------------------------------------------------------

fail() { echo "  fail: ${*:-assertion failed}" >&2; exit 1; }
skip() { echo "  skip: $*" >&2; exit 77; }

# limit SECS CMD...: kill CMD, and so fail, if it runs longer than SECS. With
# the default TERM, `docker exec` exits 0, which BusyBox `timeout` passes on.
limit() { timeout -s KILL "$@"; }

# retry SECS CMD...: run CMD until it succeeds; non-zero after SECS seconds.
# Each exec attempt is cut short: a request that reaches a server while it is
# starting can hang for many minutes although later requests are answered.
retry() {
  local deadline=$((SECONDS + $1)) EXEC_TIMEOUT=15
  shift
  until "$@" 2>/dev/null; do
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

cname() { printf '%s-%s\n' "$PREFIX" "$1"; }

# start_c NAME [docker run args...]
start_c() {
  local name=$1
  shift
  docker run -d --name "$(cname "$name")" --label "$LABEL" "$@" "$IMAGE" >/dev/null
}

logs() { docker logs "$(cname "$1")" 2>&1 || true; }

running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$(cname "$1")" 2>/dev/null)" = true ]
}

# wait_log NAME ERE [secs]: fail on timeout, or if NAME stops without a match.
wait_log() { wait_log_count "$1" "$2" 1 "${3:-180}"; }

# wait_log_count NAME ERE N [secs]: like wait_log, but wait for N matching lines.
wait_log_count() {
  local secs=${4:-180} alive n
  local deadline=$((SECONDS + secs))
  while true; do
    # Check liveness first, so lines written just before an exit are still read.
    alive=true
    running "$1" || alive=false
    n=$(grep -cE -- "$2" <<<"$(logs "$1")" || true)
    ((n >= $3)) && return 0
    if [ "$alive" = false ] || ((SECONDS >= deadline)); then
      logs "$1" | tail -n 30 >&2
      [ "$alive" = true ] || fail "$1 stopped after $n of $3 lines: $2"
      fail "$1 logged $n of $3 lines within ${secs}s: $2"
    fi
    sleep 1
  done
}

# wait_exit NAME [secs]: print the exit code.
wait_exit() {
  limit "${2:-180}" docker wait "$(cname "$1")" ||
    fail "$1 did not exit within ${2:-180}s"
}

# Execs are time-limited so that a hung command fails instead of stalling the run.
# sx NAME CMD...: exec as sandbox
sx() { limit "${EXEC_TIMEOUT:-600}" docker exec -u sandbox -e HOME=/home/sandbox "$(cname "$1")" "${@:2}"; }
# rx NAME CMD...: exec as root
rx() { limit "${EXEC_TIMEOUT:-600}" docker exec -u root "$(cname "$1")" "${@:2}"; }

# vol NAME: create a volume and print its name.
vol() {
  docker volume create --label "$LABEL" "$(cname "$1")"
}

# seed VOL PATH: write stdin to PATH, relative to the home volume VOL.
seed() {
  docker run --rm -i --label "$LABEL" -u root -v "$1:/home/sandbox" --entrypoint bash "$IMAGE" \
    -c 'mkdir -p "$(dirname "$1")" && cat >"$1"' _ "/home/sandbox/$2"
}

# rootrun VOL CMD: run CMD as root with VOL mounted as the home directory.
rootrun() {
  docker run --rm --label "$LABEL" -u root -v "$1:/home/sandbox" --entrypoint bash "$IMAGE" -c "$2"
}

# as_sandbox_with_fake TOOL [-e VAR=VALUE...] -- CMD...
# Run CMD as sandbox with a fake TOOL on PATH that prints its directory and
# arguments.
as_sandbox_with_fake() {
  local tool=$1 opts=()
  shift
  while [ "$1" != -- ]; do
    opts+=("$1")
    shift
  done
  shift
  limit 600 docker run --rm --name "$(cname "fake-$tool")" --label "$LABEL" "${opts[@]}" \
    --entrypoint bash "$IMAGE" -c '
      set -euo pipefail
      tool=$1
      shift
      dir=$(mktemp -d)
      cat >"$dir/$tool" <<"EOF"
#!/bin/sh
echo "CWD:$PWD"
for a in "$@"; do echo "ARG:$a"; done
EOF
      chmod 755 "$dir" "$dir/$tool"
      install -d -o sandbox -g sandbox /home/sandbox/workspace
      export HOME=/home/sandbox PATH="$dir:$PATH:/command"
      exec s6-setuidgid sandbox "$@"
    ' _ "$tool" "$@"
}

# need_privileged / need_socket: skip unless the run allows privileged
# containers (SMOKE_PRIVILEGED=1) or mounting the host's Docker socket
# (SMOKE_SOCKET=1).
need_privileged() { [ "${SMOKE_PRIVILEGED:-}" = 1 ] || skip "set SMOKE_PRIVILEGED=1"; }
need_socket() { [ "${SMOKE_SOCKET:-}" = 1 ] || skip "set SMOKE_SOCKET=1"; }

# docker_cp_stdin NAME PATH: write stdin to PATH in the container NAME.
docker_cp_stdin() {
  local tmp rc=0
  tmp=$(mktemp -d)
  cat >"$tmp/$(basename "$2")"
  docker cp "$tmp/$(basename "$2")" "$(cname "$1"):$2" >/dev/null || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

cleanup() {
  local ids
  set +e
  ids=$({
    docker ps -aq --filter "label=$LABEL"
    docker ps -aq --filter "name=^/?$PREFIX-"
  } | sort -u)
  # shellcheck disable=SC2086 # one argument per id
  [ -z "$ids" ] || docker rm -f -v $ids >/dev/null
  ids=$(docker volume ls -q --filter "label=$LABEL")
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker volume rm $ids >/dev/null
}

# --- tests -------------------------------------------------------------------

test_unknown_agent() {
  start_c bad -e AGENT=nope
  [ "$(wait_exit bad)" = 1 ] || fail "exit code"
  logs bad | grep -F 'Unknown AGENT: nope (valid: claude, itsaplan, opencode)' || fail "message"
}
test_claude_login_hint() {
  start_c claude
  wait_log claude 'Claude Remote Control exited'
  sleep 5; running claude || fail "must wait for login, not exit"
  logs claude | grep -F 'docker exec -it -u sandbox -e HOME=/home/sandbox <container> claude auth login' ||
    fail "login command"
  logs claude | grep -F 'docker exec -it -u sandbox -e HOME=/home/sandbox -w /home/sandbox/workspace <container> claude' ||
    fail "trust command"
}
test_claude_binary() {
  pin=$(grep -oP '^ENV CLAUDE_CODE_VERSION=\K\S+' "$ROOT/Dockerfile") || fail "no pin"
  in_image() { limit 600 docker run --rm -i --label "$LABEL" --entrypoint bash "$IMAGE" -c "$1"; }
  [ "$(in_image 'command -v claude')" = /usr/local/bin/claude ] || fail "path"
  in_image 'claude --version' | grep -F "$pin" || fail "version"
  [ "$(in_image 'stat -c "%U %a" /usr/local/bin/claude')" = "root 755" ] || fail "owner/mode"
  want=$(curl -fsS --max-time 60 "https://downloads.claude.ai/claude-code-releases/$pin/manifest.json" |
         in_image 'jq -r ".platforms[\"linux-x64\"].checksum"')
  [ "$(in_image 'sha256sum /usr/local/bin/claude | cut -d" " -f1')" = "$want" ] || fail "modified binary"
  in_image '[ "$DISABLE_UPDATES" = 1 ] && command -v bwrap >/dev/null && command -v socat >/dev/null' ||
    fail "env or sandbox tools"
  in_image '! ls /home/sandbox/.nix-profile/bin/claude 2>/dev/null' || fail "nix copy remains"
}
test_claude_quoted_args() {
  out=$(as_sandbox_with_fake claude -e "CLAUDE_RC_ARGS=--name 'two words'" -- /usr/local/lib/agents/claude.sh)
  grep -F 'ARG:two words' <<<"$out" || fail "quoting lost"
  grep -F 'CWD:/home/sandbox/workspace' <<<"$out" || fail "cwd"
}
test_itsaplan_runner() {
  out=$(as_sandbox_with_fake npx -e ITSAPLAN_RUNNER_VERSION=9.9.9 -- /usr/local/lib/agents/itsaplan.sh)
  grep -F 'ARG:@itsaplan/runner@9.9.9' <<<"$out" || fail "version"
  grep -F 'CWD:/home/sandbox/workspace' <<<"$out" || fail "cwd"
}
test_opencode_serves() {
  start_c oc -e AGENT=opencode
  retry 180 sx oc curl -fsS -o /dev/null http://127.0.0.1:8080/config || fail "no answer"
  # The agent keeps its PATH: the Nix profile first, ~/bin last.
  path=$(sx oc bash -c 'for d in /proc/[0-9]*; do
    [ "$(readlink "$d/exe" 2>/dev/null)" = /usr/local/bin/opencode ] || continue
    tr "\0" "\n" <"$d/environ" | sed -n "s/^PATH=//p"; exit; done')
  [[ $path == /home/sandbox/.nix-profile/bin:* && $path == *:/home/sandbox/bin ]] || fail "agent PATH: $path"
  dir=$(sx oc bash -c 'for d in /proc/[0-9]*; do
    [ "$(readlink "$d/exe" 2>/dev/null)" = /usr/local/bin/opencode ] || continue
    readlink "$d/cwd"; exit; done')
  [ "$dir" = /home/sandbox/workspace ] || fail "working directory: $dir"
}
test_opencode_password() {
  start_c ocpw -e AGENT=opencode -e OPENCODE_SERVER_USERNAME=u -e OPENCODE_SERVER_PASSWORD=p
  retry 180 sx ocpw curl -fsS -o /dev/null -u u:p http://127.0.0.1:8080/config || fail "auth rejected"
  [ "$(sx ocpw curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/config)" = 401 ] || fail "open"
}
test_second_start() {
  v=$(vol home)
  start_c one -v "$v:/home/sandbox"; wait_log one 'Starting agent: claude'; docker rm -f "$(cname one)"
  # Damage that the second start must repair, and a user edit it must keep.
  rootrun "$v" 'cd /home/sandbox && rm .bashrc .nix-profile && echo "# smoke: user edit" >>package.nix'
  start_c two -v "$v:/home/sandbox"; wait_log two 'Starting agent: claude'
  # The agent starts even when home initialisation fails, so check its results.
  sx two test -f /home/sandbox/.bashrc || fail "skeleton file not restored"
  sx two bash -c 'test -L ~/.nix-profile && test -x ~/.nix-profile/bin/nix-env' || fail "nix profile not restored"
  sx two grep -qxF '# smoke: user edit' /home/sandbox/package.nix || fail "user edit lost"
  ! logs two | grep -F 'init-home: WARNING' || fail "init-home warned"
}

test_no_sudo() {
  docker run --rm --label "$LABEL" --entrypoint bash "$IMAGE" -c \
    '! command -v sudo && [ ! -e /etc/sudoers.d/sandbox ] && [ -z "$(find /home_skel -not -user root)" ]' || fail
  ! docker image inspect -f '{{json .Config.Env}}' "$IMAGE" | grep -q /home/sandbox || fail "image PATH"
  # Outside the sandbox's own places, only root owns files. The exceptions are
  # Ubuntu's: apt's download dirs (_apt) and dnsmasq's runtime dir.
  others=$(docker run --rm --label "$LABEL" --entrypoint bash "$IMAGE" -c 'find / -xdev \
    \( -path /home -o -path /nix -o -path /tmp -o -path /proc -o -path /sys -o -path /dev \) -prune -o \
    -not -user root -printf "%u %p\n" 2>/dev/null' | grep -vxE '_apt /var/(cache/apt/archives|lib/apt/lists)/(partial|auxfiles)|dnsmasq /run/dnsmasq' || true)
  [ -z "$others" ] || fail "not owned by root: $others"
}
test_planted_binaries_not_run_as_root() {
  v=$(vol planted)
  seed "$v" package.nix <<'EOF'
with import <nixpkgs> {};
buildEnv { name = "user-packages"; paths = map (n: writeShellScriptBin n ''
  [ "$(id -u)" = 0 ] && touch /tmp/ran-as-root
  exec /usr/sbin/${n} "$@" '') [ "usermod" "groupadd" ] ++ [ (writeShellScriptBin "getent" ''
  [ "$(id -u)" = 0 ] && touch /tmp/ran-as-root
  exec /usr/bin/getent "$@" '') ]; }
EOF
  start_c p -v "$v:/home/sandbox" -e SANDBOX_GIDS=12345; wait_log p 'Starting agent' 600
  sx p test -x /home/sandbox/.nix-profile/bin/usermod || fail "planted package not installed"
  # Each fake runs the real tool, so a start that uses it still works.
  sx p bash -c 'mkdir -p ~/bin && for n in usermod getent rsync stat chown; do
    real=$(PATH=/usr/sbin:/usr/bin command -v $n)
    printf "#!/bin/sh\n[ \$(id -u) = 0 ] && touch /tmp/ran-as-root\nexec $real \"\$@\"\n" > ~/bin/$n; chmod +x ~/bin/$n; done'
  docker restart "$(cname p)" >/dev/null; wait_log_count p 'Starting agent' 2 600
  ! rx p test -e /tmp/ran-as-root || fail "root ran sandbox code"
}
test_symlinked_home_dir() {
  start_c s; wait_log s 'Starting agent'
  rx s bash -c 'mkdir -p /etc/canary/state/nix/profiles && touch /etc/canary/state/nix/profiles/keep'
  sx s bash -c 'mv ~/.local ~/.local.bak && ln -s /etc/canary ~/.local'
  docker restart "$(cname s)" >/dev/null; wait_log_count s 'Starting agent' 2
  rx s test -e /etc/canary/state/nix/profiles/keep || fail "root followed a symlink"
}
test_custom_uid() {
  v=$(vol uid); printf 'with import <nixpkgs> {};\nbuildEnv { name = "user-packages"; paths = [ hello ]; }\n' | seed "$v" package.nix
  start_c u -v "$v:/home/sandbox" -e SANDBOX_UID=1500 -e SANDBOX_GID=1500; wait_log u 'Starting agent' 600
  [ "$(sx u id -u)" = 1500 ] || fail uid
  sx u /home/sandbox/.nix-profile/bin/hello || fail "nix install"
}
test_uid_change_keeps_foreign_owners() {
  v=$(vol chg); start_c a -v "$v:/home/sandbox"; wait_log a 'Starting agent'; sx a touch /home/sandbox/mine
  rx a install -d -m 700 /home/sandbox/rootonly; docker rm -f "$(cname a)" >/dev/null
  start_c b -v "$v:/home/sandbox" -e SANDBOX_UID=1500; wait_log b 'Starting agent' 600
  [ "$(rx b stat -c %u /home/sandbox/mine)" = 1500 ] || fail "not re-owned"
  [ "$(rx b stat -c %u /home/sandbox/rootonly)" = 0 ] || fail "root dir re-owned"
}
# Mounts under the home, such as a project at ~/workspace, keep their owners
# when the IDs change: they may be host directories. usermod must not walk
# them either.
test_uid_change_skips_nested_mounts() {
  h=$(vol nh); w=$(vol nw); x=$(vol nx)
  rootrun "$h" 'touch /home/sandbox/mine && chown 1000:1000 /home/sandbox/mine'
  for v in "$w" "$x"; do
    docker run --rm --label "$LABEL" -u root -v "$v:/m" --entrypoint bash "$IMAGE" -c \
      'touch /m/theirs && chown -R 1000:1000 /m'
  done
  start_c n -v "$h:/home/sandbox" -v "$w:/home/sandbox/workspace" -v "$x:/home/sandbox/a b" \
    -e SANDBOX_UID=1500 -e SANDBOX_GID=1500
  wait_log n 'Starting agent' 600
  [ "$(rx n stat -c '%u %g' /home/sandbox/mine)" = "1500 1500" ] || fail "home file not re-owned"
  for p in /home/sandbox/workspace /home/sandbox/workspace/theirs "/home/sandbox/a b" "/home/sandbox/a b/theirs"; do
    [ "$(rx n stat -c '%u %g' "$p")" = "1000 1000" ] || fail "re-owned on a nested mount: $p"
  done
  [ "$(rx n getent passwd sandbox | cut -d: -f3,6)" = 1500:/home/sandbox ] || fail "account"
}
# A UID change that usermod refuses, here because another process holds the
# lock on /etc/passwd, leaves the account as it was, home directory included.
test_uid_change_failure_keeps_account() {
  out=$(limit 300 docker run --rm --label "$LABEL" -e SANDBOX_UID=1500 --entrypoint bash "$IMAGE" -c '
    export PATH=/command:$PATH
    sleep 300 & printf "%s" "$!" >/etc/passwd.lock
    bash /etc/s6-overlay/s6-rc.d/init-home/scripts/run.sh up
    getent passwd sandbox | cut -d: -f3,6' 2>&1) || fail "run: $out"
  grep -F 'could not set SANDBOX_UID=1500' <<<"$out" || fail "no warning: $out"
  [ "$(tail -n 1 <<<"$out")" = 1000:/home/sandbox ] || fail "account: $out"
}
test_taken_ids() {
  start_c g -e SANDBOX_GID=100; wait_log g 'SANDBOX_GID=100 is already used by group users'; wait_log g 'Starting agent'
  start_c i -e SANDBOX_UID=65534; wait_log i 'SANDBOX_UID=65534 is already used by user nobody'; wait_log i 'Starting agent'
}
test_root_owned_volume() {
  v=$(vol ro); rootrun "$v" 'rm -rf /home/sandbox/.local; mkdir -p /home/sandbox/.local/state/nix; chown root:root /home/sandbox'
  start_c r -v "$v:/home/sandbox"; wait_log r 'init-home: WARNING'; wait_log r 'Starting agent'
}
test_tailscale_state_warning() {
  start_c t -e TS_STATE_DIR=/home/sandbox/ts; wait_log t 'WARNING: Tailscale state path /home/sandbox/ts'
  start_c q; wait_log q 'Starting agent'; ! logs q | grep -q 'WARNING: Tailscale state' || fail "false warning"
}
# A logged-out node saves no preferences, so the state volume is seeded with a
# saved profile, as a logged-in run leaves it, whose preferences name sandbox
# as the operator. It is not running and its control server is unreachable,
# so it never logs in.
ts_state() { docker run --rm --label "$LABEL" -v "$1:/var/lib/tailscale" --entrypoint bash "$IMAGE" -c "$2" _ "${@:3}"; }
# ts_seed_prefs VOL PREFS: save a profile with the preferences PREFS (JSON).
ts_seed_prefs() {
  ts_state "$1" 'b() { printf "%s" "$1" | base64 -w0; }
    profiles="{\"a1b2\":{\"ID\":\"a1b2\",\"Name\":\"smoke\",\"Key\":\"profile-a1b2\",\"ControlURL\":\"http://127.0.0.1:9\"}}"
    printf "{\"_current-profile\":\"%s\",\"_profiles\":\"%s\",\"profile-a1b2\":\"%s\"}\n" \
      "$(b profile-a1b2)" "$(b "$profiles")" "$(b "$1")" >/var/lib/tailscale/tailscaled.state' "$2"
}
ts_seed_operator() { ts_seed_prefs "$1" '{"ControlURL":"http://127.0.0.1:9","WantRunning":false,"OperatorUser":"sandbox"}'; }
ts_saved_operator() {
  ts_state "$1" 'jq -er ".\"profile-a1b2\" | @base64d | fromjson | .OperatorUser // \"\"" /var/lib/tailscale/tailscaled.state'
}
test_tailscale_agent_control_opt_in() {
  s=$(vol tsstate); ts_seed_operator "$s"; [ "$(ts_saved_operator "$s")" = sandbox ] || fail "seed"
  start_c tsd -v "$s:/var/lib/tailscale"; wait_log tsd 'Starting agent'
  ! sx tsd tailscale set --ssh=false || fail "granted by default"; docker rm -f "$(cname tsd)" >/dev/null
  start_c tse -v "$s:/var/lib/tailscale" -e TS_OPERATOR=true; wait_log tse 'Starting agent'
  sx tse tailscale set --ssh=false || fail "opt-in refused"; docker rm -f "$(cname tse)" >/dev/null
  [ "$(ts_saved_operator "$s")" = sandbox ] || fail "opt-in grant not saved"
  start_c tsf -v "$s:/var/lib/tailscale" -e TS_OPERATOR=1; wait_log tsf 'Starting agent'
  ! sx tsf tailscale set --ssh=false || fail "saved grant survived"
  [ "$(ts_saved_operator "$s")" = "" ] || fail "revocation not saved"
  # s6 restarts a crashed tailscaled from the state, which must keep no operator.
  rx tsf bash -c 'for d in /proc/[0-9]*; do
    [ "$(readlink "$d/exe")" = /usr/sbin/tailscaled ] && kill -KILL "${d#/proc/}"; done; exit 0'
  sleep 2; retry 60 rx tsf tailscale debug prefs >/dev/null || fail "tailscaled did not come back"
  ! sx tsf tailscale set --ssh=false || fail "grant restored by a tailscaled restart"
}
# A saved setting that the environment does not pass makes `tailscale up`
# fail and print the command it wants, which must not contain the auth key.
# The key is a dummy, and the control server is unreachable.
test_tailscale_up_failure_hides_key() {
  s=$(vol tskey); ts_seed_prefs "$s" '{"ControlURL":"http://127.0.0.1:9","WantRunning":false,"RunSSH":true}'
  start_c tk -v "$s:/var/lib/tailscale" -e TS_AUTH_KEY=tskey-auth-smokedummy-0000; wait_log tk 'Starting agent'
  wait_log tk 'requires mentioning all'
  wait_log tk '^\[tailscale\] tailscale up failed'
  ! logs tk | grep -F smokedummy || fail "auth key in the log"
  ! rx tk test -e /run/harness/tailscale-auth-key || fail "key file left"
}
# ts_up_fake [docker run args...]: run the tailscale service's `up` with a
# fake tailscale that prints its user, its arguments and the key file's
# contents and mode, then say whether the key file is left.
ts_up_fake() {
  limit 300 docker run --rm --label "$LABEL" "$@" --entrypoint bash "$IMAGE" -c '
    cat >/usr/local/sbin/tailscale <<"EOF"
#!/bin/bash
[ "$1" = up ] || exit 0
echo "ID:$(id -un)"
for a in "$@"; do
  echo "ARG:$a"
  case $a in --auth-key=file:/run/*)
    f=${a#--auth-key=file:}; echo "KEY:$(cat "$f")"; echo "MODE:$(stat -c "%U:%G %a" "$f")" ;;
  esac
done
[ -z "${FAKE_FAIL:-}" ]
EOF
    chmod 755 /usr/local/sbin/tailscale
    export PATH=/command:$PATH
    bash /etc/s6-overlay/s6-rc.d/tailscale/scripts/tailscale.sh up
    if [ -e /run/harness/tailscale-auth-key ]; then echo KEYFILE:left; else echo KEYFILE:gone; fi' 2>&1
}
# expect OUTPUT LINE...: fail unless OUTPUT has each LINE.
expect() {
  local out=$1 l
  shift
  for l in "$@"; do grep -qF -- "$l" <<<"$out" || fail "missing $l in: $out"; done
}
# Every TS_* variable reaches tailscale or tailscaled, an inherited ARGS does
# not, and the key is passed in a file that is removed afterwards.
test_tailscale_args() {
  out=$(ts_up_fake -e ARGS=--inherited -e TS_AUTH_KEY=tskey-auth-smokedummy -e TS_HOSTNAME=h \
    -e TS_ROUTES=10.0.0.0/24 -e TS_ACCEPT_ROUTES=true -e "TS_EXTRA_ARGS=--ssh --accept-dns=false")
  expect "$out" ID:root ARG:--hostname=h ARG:--advertise-routes=10.0.0.0/24 ARG:--accept-routes ARG:--ssh \
    ARG:--accept-dns=false ARG:--auth-key=file:/run/harness/tailscale-auth-key KEY:tskey-auth-smokedummy \
    "MODE:root:root 600" KEYFILE:gone
  ! grep -E 'ARG:.*(smokedummy|--inherited)' <<<"$out" || fail "key or ARGS passed: $out"
  out=$(ts_up_fake -e TS_OPERATOR=true -e TS_AUTH_KEY=tskey-auth-smokedummy)
  expect "$out" ID:sandbox KEY:tskey-auth-smokedummy "MODE:root:sandbox 640" KEYFILE:gone
  out=$(ts_up_fake -e TS_AUTH_KEY=file:/etc/hostname)
  expect "$out" ARG:--auth-key=file:/etc/hostname KEYFILE:gone
  out=$(ts_up_fake -e FAKE_FAIL=1 -e TS_AUTH_KEY=tskey-auth-smokedummy)
  expect "$out" '[tailscale] tailscale up failed' KEYFILE:gone
  out=$(ts_up_fake -e ARGS=--inherited)
  ! grep -F ARG: <<<"$out" || fail "up without a key: $out"
  tsd() {
    limit 120 docker run --rm --label "$LABEL" "$@" --entrypoint bash "$IMAGE" -c '
      printf "#!/bin/sh\nfor a; do echo \"ARG:\$a\"; done\n" >/usr/local/sbin/tailscaled
      chmod 755 /usr/local/sbin/tailscaled
      PATH=/command:$PATH sh /etc/s6-overlay/s6-rc.d/tailscaled/run' 2>&1
  }
  out=$(tsd -e ARGS=--inherited -e TS_STATE_DIR=/var/lib/x -e TS_STATE=mem:)
  expect "$out" ARG:--statedir=/var/lib/x ARG:--state=mem: ARG:--tun=userspace-networking
  ! grep -F -- --inherited <<<"$out" || fail "tailscaled got ARGS: $out"
  out=$(tsd -e TS_USERSPACE=false)
  ! grep -F ARG: <<<"$out" || fail "kernel networking: $out"
}
# Kernel networking needs /dev/net/tun, which an unprivileged container lacks,
# so tailscaled never starts.
test_tailscale_revoke_fails_closed() {
  start_c fc -e TS_USERSPACE=false
  [ "$(wait_exit fc 240)" = 1 ] || fail exit
  logs fc | grep -qF 'Cannot confirm that the sandbox user has no Tailscale control' || fail message
  ! logs fc | grep -qF 'Starting agent' || fail "agent started"
  ! logs fc | grep -E '^\[(init-home|nix-packages)\]' || fail "a sandbox service ran"
}

dind() { need_privileged; start_c "$1" --privileged -e DOCKER_DIND=true -e AGENT=opencode "${@:2}"; wait_log "$1" 'Starting agent'; }
test_docker_tools() { docker run --rm --label "$LABEL" --entrypoint bash "$IMAGE" -c 'docker compose version && docker buildx version' || fail; }
test_docker_off_by_default() {
  start_c off; wait_log off 'Starting agent'
  ! sx off docker info >/dev/null 2>&1 || fail "daemon running"
}
test_dind_needs_privileged() {
  start_c np -e DOCKER_DIND=true; [ "$(wait_exit np)" = 1 ] || fail exit
  logs np | grep -F 'needs a privileged container' || fail message
}
# Cgroups are nested only in a private cgroup namespace. The guard reads the
# file it is given, so no container ever runs in the host's namespace.
test_dind_cgroupns_guard() {
  docker run --rm --label "$LABEL" --entrypoint bash "$IMAGE" -c '
    . /usr/local/lib/harness/dind.sh; f=$(mktemp)
    for c in "0::/" "0::/init"; do
      echo "$c" >"$f"; dind_cgroupns_private "$f" || { echo "rejected $c"; exit 1; }
    done
    for c in "0::/system.slice/docker-1.scope" "0::/init.scope" "0::/../init.scope" "0::/init/x" \
             "12:cpu:/" "$(printf "0::/\n0::/x")" ""; do
      printf "%s\n" "$c" >"$f"; ! dind_cgroupns_private "$f" || { echo "accepted $c"; exit 1; }
    done
    ! dind_cgroupns_private /nonexistent || { echo "accepted a missing file"; exit 1; }' || fail
  need_privileged
  out=$(docker run --rm --label "$LABEL" --privileged --entrypoint bash "$IMAGE" -c '
    . /usr/local/lib/harness/dind.sh; f=$(mktemp); echo 0::/system.slice/docker-1.scope >"$f"
    dind_check /proc/1/cgroup || exit 3; ! dind_check "$f" || exit 4' 2>&1) || fail "check: $out"
  grep -F 'needs cgroup v2 and a private cgroup namespace' <<<"$out" || fail "message: $out"
}
test_dind_socket_conflict() {
  need_socket; start_c sc -e DOCKER_DIND=true -v /var/run/docker.sock:/var/run/docker.sock
  [ "$(wait_exit sc)" = 1 ] || fail exit; logs sc | grep -F 'conflicts with a host socket' || fail message
}
# A privileged container with a socket at /var/run/docker.sock is refused too.
# The mount is a file of the test container's own, not the host's socket.
test_dind_socket_conflict_privileged() {
  need_privileged
  out=$(docker run --rm --label "$LABEL" --privileged --entrypoint bash "$IMAGE" -c '
    . /usr/local/lib/harness/dind.sh; dind_check || exit 3
    touch /tmp/sock /var/run/docker.sock && mount --bind /tmp/sock /var/run/docker.sock
    ! dind_check' 2>&1) || fail "check: $out"
  grep -F 'conflicts with a host socket' <<<"$out" || fail "message: $out"
}
# A host /run, or a host directory at /run/docker or /run/containerd or under
# them, is refused like a socket. The mounts are scratch directories of the
# test container's own. Mounts under /run/docker are refused only before this
# container's own dockerd has started (dind_mark), since dockerd makes some.
test_dind_run_dir_conflict() {
  need_privileged
  out=$(docker run --rm --label "$LABEL" --privileged --entrypoint bash "$IMAGE" -c '
    . /usr/local/lib/harness/dind.sh; dind_check || exit 3
    mkdir -p /tmp/s /run/docker/plugins /run/containerd
    mount --bind /tmp/s /run/docker/plugins; ! dind_check || exit 4
    dind_mark; dind_check || exit 5; rm -f /run/harness/dind-checked; umount /run/docker/plugins
    mount --bind /tmp/s /run/containerd; dind_mark; ! dind_check || exit 6; umount /run/containerd
    mount --bind /tmp/s /var/run; ! dind_check || exit 7' 2>&1) || fail "check: $out"
  [ "$(grep -cF 'conflicts with a host socket' <<<"$out")" = 3 ] || fail "message: $out"
}
# A shared host network shows a docker0 link or a DOCKER chain before this
# container's dockerd has made its own. Both are made in the test container's
# own network namespace.
test_dind_host_network() {
  need_privileged
  out=$(docker run --rm --label "$LABEL" --privileged --entrypoint bash "$IMAGE" -c '
    . /usr/local/lib/harness/dind.sh; dind_check || exit 3
    ip link add docker0 type bridge; ! dind_check || exit 4
    dind_mark; dind_check || exit 5; rm -f /run/harness/dind-checked; ip link del docker0
    iptables -t nat -N DOCKER; ! dind_check || exit 6' 2>&1) || fail "check: $out"
  [ "$(grep -cxF "DOCKER_DIND=true cannot share the host's network: remove --network=host" <<<"$out")" = 2 ] ||
    fail "message: $out"
}
# s6 restarts a crashed dockerd; its own docker0 and mounts must not stop it.
test_dind_daemon_crash() {
  dind cr; sx cr docker run --rm hello-world >/dev/null || fail "first run"
  rx cr bash -c 'kill -KILL "$(cat /run/docker.pid)"'
  retry 90 sx cr docker run --rm hello-world >/dev/null || fail "daemon did not come back"
}
test_dind_runs_container() {
  v=$(vol dlib); dind d -v "$v:/var/lib/docker"
  sx d docker run --rm alpine:3 wget -q -O /dev/null https://example.com || fail "run or network"
  sx d docker compose version && sx d docker buildx version || fail "plugins as sandbox"
}
test_dind_without_volume() { dind nv; sx nv docker run --rm hello-world || fail; }
test_dind_restart() {
  dind rs; docker restart -t 30 "$(cname rs)"; wait_log_count rs 'Starting agent' 2
  sx rs docker info >/dev/null || fail "daemon did not return"
}
test_dind_clean_stop() {
  dind st; sx st docker run -d alpine:3 sleep 600
  docker stop -t 30 "$(cname st)"; logs st | grep -F 'Daemon shutdown complete' || fail
}
test_dind_not_ready() {
  need_privileged
  docker create --name "$(cname nr)" --label "$LABEL" --privileged -e DOCKER_DIND=true "$IMAGE" >/dev/null
  echo '{ broken' | docker_cp_stdin nr /etc/docker/daemon.json; docker start "$(cname nr)"
  [ "$(wait_exit nr 180)" = 1 ] || fail exit; logs nr | grep -F 'did not become ready within 60s' || fail message
}
test_socket_mode() {
  need_socket
  gid=$(docker run --rm --label "$LABEL" -v /var/run/docker.sock:/s --entrypoint stat "$IMAGE" -c %g /s)
  start_c so -v /var/run/docker.sock:/var/run/docker.sock -e "SANDBOX_GIDS=$gid" -e AGENT=opencode
  wait_log so 'Starting agent'; sx so docker version >/dev/null || fail
}

# --- runner ------------------------------------------------------------------

trap cleanup EXIT
trap 'exit 130' INT TERM

ran=0
failed=0
for t in $(compgen -A function test_); do
  [[ $t == *"$FILTER"* ]] || continue
  ran=$((ran + 1))
  # Not part of a condition, so errexit stays in force inside the subshell.
  set +e
  (
    set -e
    "$t"
  )
  rc=$?
  set -e
  case $rc in
    0) echo "PASS $t" ;;
    77) echo "SKIP $t" ;;
    *)
      echo "FAIL $t"
      failed=$((failed + 1))
      ;;
  esac
done

((ran > 0)) || { echo "no test matches: $FILTER" >&2; exit 2; }
echo "$ran run, $failed failed"
((failed == 0))
