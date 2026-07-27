#!/usr/bin/env bash
# Starts the Docker dedicated server and waits for the world to finish starting.
# Usage: 01-start-server.sh <profile>
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$BIN_DIR")"
# shellcheck source=lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=lib/docker-server.sh
source "$ROOT_DIR/lib/docker-server.sh"

[ $# -eq 1 ] || die "usage: $0 <profile>"
load_profile "$1"

require_cmd docker
require_var DOCKER_COMPOSE_DIR
[ -d "$DOCKER_COMPOSE_DIR" ] || die "DOCKER_COMPOSE_DIR does not exist: $DOCKER_COMPOSE_DIR"

docker_server_start
# 300s is enough for a normal load of an already-generated world, but a first-ever boot
# against a brand-new WorldGenSeed (see docs/lessons-learned.md on why a fresh world is
# used per profile) can take 5+ minutes, especially with the v2.6 line's The Wasteland
# overhaul mod - observed 340s in testing.
docker_server_wait_started 480
log "server is up"
