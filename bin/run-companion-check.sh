#!/usr/bin/env bash
# Runs the companion scenario end to end. Kept as its own entry point because the runbook and
# habit both name it; the driver itself is bin/run-scenario-check.sh, which every focused
# scenario shares - the stages either side of the scenario are identical, and there is no
# reason for a third copy of them.
#
# Usage: run-companion-check.sh --profile <v3|v26> [--mode connect|hostload]
#                               [--package <zip>] [--keep-save] [--persistent-save]
set -uo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$BIN_DIR/run-scenario-check.sh" --scenario companion "$@"
