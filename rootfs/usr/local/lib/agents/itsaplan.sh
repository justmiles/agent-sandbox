#!/usr/bin/env bash
# @itsaplan/runner. Runs as sandbox.

set -euo pipefail

cd /home/sandbox/workspace
exec npx -y "@itsaplan/runner@${ITSAPLAN_RUNNER_VERSION:-latest}"
