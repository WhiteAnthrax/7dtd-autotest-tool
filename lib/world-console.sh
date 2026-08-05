#!/usr/bin/env bash
# Runs a console command wherever the world actually lives, which is not the same place in
# every topology:
#
#   connect  - the client joins a dedicated server. The world, and every entity in it, lives
#              in the server process; the client only has a replica. Commands go through
#              lib/server-console.sh.
#   hostload - the client hosts the world itself. There is no second process, so commands go
#              through the client's own command queue.
#
# Scenarios that touch entities have to use this rather than picking a helper directly. The
# cost of getting it wrong is not an error but a plausible wrong answer: a marker written to
# a client-side replica is invisible to the server code that reads it, and an entity spawned
# on the client does not exist server-side at all. Both happened - see docs/lessons-learned.md.
#
# TESTPILOT_MODE selects the topology and defaults to connect, matching 04-launch-client.sh.
# Source after lib/common.sh, lib/testpilot-queue.sh and lib/server-console.sh.

# world_console <command> [expect_substring] [timeout_seconds]: runs the command where the
# world is and prints its console output as plain text.
#
# expect_substring is only meaningful in connect mode, where the reply arrives asynchronously
# on the server's log stream and there is nothing to block on. The client queue already waits
# for its own result file, so the argument is accepted and ignored there.
world_console() {
    local command="$1"
    local expect="${2:-}"
    local timeout="${3:-20}"

    case "${TESTPILOT_MODE:-connect}" in
        hostload)
            submit_and_check "$command" | jq -r '.output'
            ;;
        connect)
            server_console_checked "$command" "$expect" "$timeout" | grep -v "Executing command" || true
            ;;
        *)
            die "unknown TESTPILOT_MODE '${TESTPILOT_MODE}' (expected connect or hostload)"
            ;;
    esac
}

# world_le: the entity list, from whichever side owns it.
world_le() {
    world_console "le" "Total of"
}

# world_player_id <le output>: the local player's entity id.
#
# The type differs by topology - EntityPlayerLocal when the client hosts, EntityPlayer for a
# remote player as the server sees them - so match both rather than the one that happened to
# be in front of us.
world_player_id() {
    printf '%s' "$1" | grep -oP '\[type=EntityPlayer(?:Local)?, name=[^,]*, id=\K[0-9]+' | head -1 || true
}

# world_log_grep_count <pattern>: how many lines matching <pattern> the game logged.
#
# Which log that is follows the topology, and getting it wrong is quiet rather than loud: a
# hostload run counted zero "Gathered" lines because it was reading the *dedicated server's*
# log while the game was running entirely inside the client.
#
#   connect  - the server's own output_log__*.txt, on this machine.
#   hostload - the client is the game, and Unity writes its log to
#              %USERPROFILE%\AppData\LocalLow\The Fun Pimps\7 Days To Die\Player.log
#              (not the game folder, and not the older AppData\Roaming location that still
#              has stale files in it).
# client_log_grep_count <pattern>: how many lines matching <pattern> the *client* logged,
# whichever topology this is.
#
# Not everything the mod does is server-side even when there is a server. Charging a remote
# player happens on their client ("Consumed local travel cost for ..."), as does the warning
# when it removed the wrong number of items - so counting those in the server's log finds
# nothing and says the code never ran.
client_log_grep_count() {
    local pattern="$1"
    run_on_omen_cmd "\$p = Join-Path \$env:USERPROFILE 'AppData\\LocalLow\\The Fun Pimps\\7 Days To Die\\Player.log'; if (Test-Path \$p) { (Select-String -Path \$p -Pattern '${pattern}' -AllMatches | Measure-Object).Count } else { 0 }" \
        | tr -d '\r' | grep -oE '^[0-9]+' | head -1 || printf '0'
}

world_log_grep_count() {
    local pattern="$1"
    case "${TESTPILOT_MODE:-connect}" in
        hostload)
            client_log_grep_count "$pattern"
            ;;
        connect)
            local log
            log="$(docker_server_latest_log)"
            if [ -n "$log" ]; then
                grep -c "$pattern" "$log" || true
            else
                printf '0'
            fi
            ;;
    esac
}

# world_spawn_entity <prefab> <spawn command>: spawns one entity and returns *its* id.
#
# Not "the first id with that name in `le`" - the world already has traders, and picking one
# of those instead of the entity just created is silent: the id is real, the entity exists,
# and only something later fails. A paging run picked up a world trader 120m away and then
# could not open its dialog; the previous scenarios had simply been lucky.
#
# So the ids for that prefab are read before and after, and the difference is the answer.
world_spawn_entity() {
    local prefab="$1" spawn_cmd="$2" before after new_id attempt
    before="$(world_le | grep -oP "name=${prefab}, id=\K[0-9]+" | sort -u || true)"
    for attempt in 1 2 3; do
        world_console "$spawn_cmd" "" 10 >/dev/null
        sleep 3
        after="$(world_le | grep -oP "name=${prefab}, id=\K[0-9]+" | sort -u || true)"
        new_id="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1 || true)"
        if [ -n "$new_id" ]; then
            printf '%s' "$new_id"
            return 0
        fi
        log "attempt ${attempt}: no new ${prefab} appeared in the entity list yet"
    done
    return 1
}
