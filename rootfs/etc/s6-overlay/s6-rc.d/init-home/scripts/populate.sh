#!/usr/bin/env bash
# Fills the home directory from the skeleton. Runs as sandbox. A step that
# fails is reported and the rest still run, so the agent can start.

set -uo pipefail

warn() { echo "init-home: WARNING: $1; check ownership of $2"; }

[ -d /home_skel ] || exit 0

echo "Initializing /home/sandbox from skeleton..."

# Copy what is missing. The files become sandbox's, with sandbox's umask.
rsync -a --no-owner --no-group --no-perms --omit-dir-times --ignore-existing /home_skel/ /home/sandbox/ ||
  warn "copying the skeleton failed" /home/sandbox

# Always overwrite the Nix profile links from the skeleton, so they point to
# the image's store paths, and drop generations left by earlier images.
if [ -d /home_skel/.local/state/nix/profiles ]; then
  rm -f /home/sandbox/.nix-profile &&
    rm -rf /home/sandbox/.local/state/nix/profiles &&
    mkdir -p /home/sandbox/.local/state/nix &&
    cp -af /home_skel/.nix-profile /home/sandbox/.nix-profile &&
    cp -af /home_skel/.local/state/nix/profiles /home/sandbox/.local/state/nix/profiles ||
    warn "resetting the Nix profile failed" /home/sandbox/.local/state/nix
fi

exit 0
