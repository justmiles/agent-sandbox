#!/command/with-contenv bash
# Sets the sandbox user's IDs and the ownership of its files, then fills the
# home directory as sandbox. Runs as root, so it only changes ownership in
# places the sandbox user can write, and never runs code or copies files there.

. /usr/local/lib/harness/root-env.sh

set -euo pipefail

warn() { echo "init-home: WARNING: $*"; }

# set_id VAR VALUE: change the sandbox UID (VAR=SANDBOX_UID) or GID to VALUE.
# A change that cannot be made is reported, and the current ID kept.
set_id() {
  local var=$1 want=$2 kind cur db what cmd owner
  if [ "$var" = SANDBOX_UID ]; then
    kind=UID db=passwd what=user cmd=(usermod -u) cur=$(id -u sandbox)
  else
    kind=GID db=group what=group cmd=(groupmod -g) cur=$(getent group sandbox | cut -d: -f3)
  fi
  [ "$want" = "$cur" ] && return 0
  case $want in
    '' | *[!0-9]*) warn "$var=$want is not a number; keeping $kind $cur"; return 0 ;;
  esac
  if owner=$(getent "$db" "$want"); then
    warn "$var=$want is already used by $what ${owner%%:*}; keeping $kind $cur"
    return 0
  fi
  if [ "$kind" = UID ]; then
    # usermod -u re-owns the old UID's files in the home directory itself,
    # mounts under it included. Point the account at a home that does not
    # exist for the change, so that only home_tree re-owns them.
    if [ -e "$NO_HOME" ]; then
      warn "$NO_HOME exists; keeping $kind $cur"
      return 0
    fi
    cmd+=("$want" -d "$NO_HOME")
  else
    cmd+=("$want")
  fi
  if ! "${cmd[@]}" sandbox; then
    warn "could not set $var=$want; keeping $kind $cur"
  fi
  # usermod changes the UID and the home in one step, or neither. Set the home
  # back either way.
  if [ "$kind" = UID ] && [ "$(getent passwd sandbox | cut -d: -f6)" != /home/sandbox ]; then
    usermod -d /home/sandbox sandbox || warn "could not set the home directory of sandbox back to /home/sandbox"
  fi
}

# reown OLD_UID OLD_GID CMD...: run CMD --from=OLD NEW for the UID and the GID
# that changed, so that only what the old IDs owned becomes sandbox's. Files
# of any other owner, root's above all, are left alone, and root (0) is never
# an old ID.
reown() {
  local u=$1 g=$2
  shift 2
  if [ "$u" != 0 ] && [ "$u" != "$uid" ]; then
    "$@" --from="$u" "$uid" || warn "could not re-own files of UID $u ($1)"
  fi
  if [ "$g" != 0 ] && [ "$g" != "$gid" ]; then
    "$@" --from=":$g" ":$gid" || warn "could not re-own files of GID $g ($1)"
  fi
}

# Only root can create this path, and it must not exist.
NO_HOME=/nonexistent

# nested_mounts: print, NUL-separated, every mount point under /home/sandbox
# but not the home itself, such as a project mounted at ~/workspace. They may
# be host directories, so their files keep their owners. Mount points are
# read from mountinfo: `find -xdev` misses bind mounts and volumes on the
# same device. mountinfo escapes space, tab, newline and backslash as octal.
nested_mounts() {
  local _ mp
  while read -r _ _ _ _ mp _; do
    mp=${mp//\\040/ }
    mp=${mp//\\011/$'\t'}
    mp=${mp//\\012/$'\n'}
    mp=${mp//\\134/\\}
    case $mp in /home/sandbox/?*) printf '%s\0' "$mp" ;; esac
  done </proc/self/mountinfo
}

# home_tree ARGS...: chown -h ARGS every file in the home directory, without
# following symlinks and without entering or changing a nested mount.
home_tree() {
  local prune=() m
  while IFS= read -r -d '' m; do
    # find -path takes a pattern: quote its special characters.
    m=${m//\\/\\\\}
    m=${m//\*/\\*}
    m=${m//\?/\\?}
    m=${m//\[/\\[}
    prune+=(-o -path "$m")
  done < <(nested_mounts)
  if ((${#prune[@]})); then
    prune=(\( "${prune[@]:1}" \) -prune -o)
  fi
  find /home/sandbox "${prune[@]}" -print0 | xargs -0 -r chown -h "$@"
}

# Store files are read-only, so only the store's directories are re-owned,
# which is what Nix needs to add and delete paths. Re-owning every file would
# copy the whole store out of the image layer, which can take hours.
nix_tree() {
  chown -h "$@" /nix /nix/store && chown -R -h "$@" /nix/var &&
    find /nix/store -xdev -mindepth 1 -type d -print0 | xargs -0 -r chown -h "$@"
}

up () {
  # Read the owners first: usermod re-owns some of the home itself.
  local home_ids nix_ids
  home_ids=$(stat -c '%u %g' /home/sandbox)
  nix_ids=$(stat -c '%u %g' /nix)

  if [ -n "${SANDBOX_UID:-}" ]; then set_id SANDBOX_UID "$SANDBOX_UID"; fi
  if [ -n "${SANDBOX_GID:-}" ]; then set_id SANDBOX_GID "$SANDBOX_GID"; fi

  uid=$(id -u sandbox)
  gid=$(getent group sandbox | cut -d: -f3)
  # shellcheck disable=SC2086 # two words: UID and GID
  reown $home_ids home_tree
  chown -h sandbox:sandbox /home/sandbox || warn "could not chown /home/sandbox"
  # shellcheck disable=SC2086
  reown $nix_ids nix_tree

  s6-setuidgid sandbox env HOME=/home/sandbox /etc/s6-overlay/s6-rc.d/init-home/scripts/populate.sh
}

$1 2>&1 | s6-log -bp n3 "p[init-home]" 1 /var/log/init-home
