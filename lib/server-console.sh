#!/usr/bin/env bash
# Runs console commands on the dedicated server, as opposed to on the client.
#
# The distinction matters more than it sounds. `lib/testpilot-queue.sh` submits commands to
# the *client* process, where SdtdConsole.ExecuteSync sees IsLocalGame and never forwards
# them. Anything that has to touch server-side state - the entities the server owns, the
# code that runs there - has to come in this way instead. Getting that wrong once produced a
# test that marked an entity on the client and then wondered why server-side code disagreed
# (see docs/lessons-learned.md).
#
# Route: the server's telnet listener binds to loopback *inside the container* whenever
# TelnetPassword is empty, which is the shipped default. The compose file publishes the port,
# so a connection from this host is accepted by Docker's proxy and then reaches nothing. Going
# in through `docker exec` lands inside that loopback and works without changing the server's
# configuration or setting a password.
#
# Requires config vars DOCKER_CONTAINER_NAME and DOCKER_COMPOSE_DIR. Source after
# lib/common.sh.

# server_console_port: TelnetPort from the server's own config, defaulting to the stock 8081.
server_console_port() {
    require_var DOCKER_COMPOSE_DIR
    local config="${DOCKER_COMPOSE_DIR}/data/serverfiles/sdtdserver.xml"
    local port=""
    if [ -f "$config" ]; then
        port="$(grep -oP '<property name="TelnetPort"\s*value="\K[0-9]+' "$config" | head -1 || true)"
    fi
    printf '%s' "${port:-8081}"
}

# server_console <command> [expect_pattern] [timeout_seconds]: runs one console command on the
# server and prints everything the console said.
#
# The console answers asynchronously and the reply arrives on the log stream, so there is
# nothing to block on. A fixed sleep was tried first and was simply wrong: two seconds looked
# generous and still cut off a `vtttest` result. When the caller knows a substring the reply
# will contain, pass it and this returns as soon as it appears - and otherwise waits the full
# timeout rather than guessing.
#
# The command travels as an environment variable rather than inside the here-doc, so nothing
# in it has to survive two levels of shell quoting. The helper is fed on stdin instead of
# being copied in, so no file is left behind in the container.
server_console() {
    require_var DOCKER_CONTAINER_NAME
    local command="$1"
    local expect="${2:-}"
    local timeout="${3:-15}"
    local port
    port="$(server_console_port)"

    docker exec -i \
        -e "VTT_SERVER_CMD=${command}" \
        -e "VTT_TELNET_PORT=${port}" \
        -e "VTT_EXPECT=${expect}" \
        -e "VTT_TIMEOUT=${timeout}" \
        "$DOCKER_CONTAINER_NAME" python3 - <<'PYEOF'
import os, socket, sys, time

port = int(os.environ["VTT_TELNET_PORT"])
command = os.environ["VTT_SERVER_CMD"]
expect = os.environ.get("VTT_EXPECT", "")
timeout = float(os.environ.get("VTT_TIMEOUT", "15"))

try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=15)
except OSError as exc:
    sys.stderr.write("could not reach the server console on 127.0.0.1:%d: %s\n" % (port, exc))
    sys.exit(1)

sock.settimeout(0.5)


def read_available():
    chunks = b""
    try:
        while True:
            data = sock.recv(8192)
            if not data:
                break
            chunks += data
    except socket.timeout:
        pass
    return chunks


read_available()  # the connection banner, which is not part of any command's output
sock.sendall(command.encode("utf-8") + b"\r\n")

collected = b""
deadline = time.monotonic() + timeout
while time.monotonic() < deadline:
    collected += read_available()
    if expect and expect.encode("utf-8") in collected:
        break

try:
    sock.sendall(b"exit\r\n")
except OSError:
    pass
sock.close()

sys.stdout.write(collected.decode("utf-8", "replace"))
PYEOF
}

# server_console_checked <command> [expect_pattern] [timeout_seconds]: as server_console, but
# dies when the command could not be delivered, and - when an expect pattern is given - when
# the reply never arrived. Without a pattern it cannot tell a command that failed from one
# that printed nothing, so callers should pass one whenever they know what to look for.
server_console_checked() {
    local command="$1"
    local expect="${2:-}"
    local timeout="${3:-15}"
    local output
    if ! output="$(server_console "$command" "$expect" "$timeout")"; then
        die "could not run '$command' on the server console"
    fi
    if [ -n "$expect" ] && ! printf '%s' "$output" | grep -qF "$expect"; then
        die "server console ran '$command' but '$expect' never appeared within ${timeout}s. Output was: $output"
    fi
    printf '%s' "$output"
}
