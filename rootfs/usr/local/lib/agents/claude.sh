#!/usr/bin/env bash
# Claude Code Remote Control. Runs as sandbox.

set -euo pipefail

cd /home/sandbox/workspace

# `script` allocates a terminal, which keeps the status screen from flooding the
# log. -e makes it return the command's exit status, so a failure reaches here.
script -qe -c "claude rc ${CLAUDE_RC_ARGS:-}" /dev/null || {
  echo ""
  echo "================================================================"
  echo "  Claude Remote Control exited. Authentication or workspace trust"
  echo "  may be required."
  echo ""
  echo "  To authenticate, run:"
  echo "    docker exec -it -u sandbox -e HOME=/home/sandbox <container> claude auth login"
  echo ""
  echo "  If it reports that the workspace isn't trusted, run Claude Code"
  echo "  there once and accept the trust dialog:"
  echo "    docker exec -it -u sandbox -e HOME=/home/sandbox -w /home/sandbox/workspace <container> claude"
  echo ""
  echo "  Waiting 5 minutes before exiting to allow time to log in..."
  echo "================================================================"
  sleep 300
  exit 1
}
