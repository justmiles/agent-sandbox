#!/usr/bin/env bash
# OpenCode server. Runs as sandbox.

set -euo pipefail

OPENCODE_ARGS="${OPENCODE_ARGS:---hostname 0.0.0.0 --port 8080}"

cd /home/sandbox/workspace
# Unquoted on purpose: each word of OPENCODE_ARGS is a separate argument.
exec /usr/local/bin/opencode serve $OPENCODE_ARGS
