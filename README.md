# 7dtd-autotest-tool

Headless test automation for 7 Days To Die mods, built around two pieces:

- **`SdtdTestPilot`** (`src/SdtdTestPilot/`, `src/SdtdTestPilot.Core/`) - a test-only mod
  that auto-connects (or auto-hosts) a game client on startup and lets an external
  driver inject console commands through local files, with no human clicking through
  menus. It doesn't know anything about any particular mod under test.
- **Orchestration scripts** (`bin/`, `lib/`) - a bash pipeline that starts a Docker
  dedicated server, builds and deploys Debug mod binaries, drives `SdtdTestPilot`'s
  command queue through a test scenario, verifies the result against server-side save
  data, and tears everything back down - even on failure.

The included default scenario exercises
[VisitedTraderTeleport](https://github.com/WhiteAnthrax/VisitedTraderTeleport)'s
`vtttest` console command (`record`/`list`/`teleport`), but the queue-driving parts of
this tool don't depend on that mod - only `bin/05-run-scenario.sh` and `bin/06-verify.sh`
are VisitedTraderTeleport-specific.

**Never install `SdtdTestPilot` on a real or public server, and never ship it.** See
`docs/overview.md` for the safety gates and `docs/HeadlessTestDriver.md` for the full
protocol reference.

## Requirements

- A Linux machine with `bash`, `docker`/`docker compose`, `jq`, `git`, `ssh`/`scp`.
- A Windows build/test host reachable via `ssh <host>` (see `~/.ssh/config`), with the
  .NET SDK, and a 7 Days To Die client install.
- A Docker-based 7DTD dedicated server on the Linux machine (this repo doesn't manage
  the server itself - point `DOCKER_COMPOSE_DIR` at an existing compose project).

## Quick start

```bash
cp config/v3.env.example config/v3.env
# edit config/v3.env: fill in OMEN_USER_ID and any paths that differ in your environment

./bin/run-roundtrip.sh --profile v3
```

This runs the full pipeline (start server -> build mods -> deploy -> launch client ->
run scenario -> verify -> tear down) and prints a final `ROUNDTRIP_RESULT {...}` JSON
line. Exit code 0 means the whole thing passed.

See `docs/runbook.md` for a step-by-step walkthrough (including running each stage
individually) and `docs/lessons-learned.md` before you go modifying anything - several
non-obvious pitfalls are documented there from hard-won debugging sessions.

## Layout

```
bin/            Entry point (run-roundtrip.sh) and its numbered stages (01-07)
lib/            Shared bash helpers + Windows-side PowerShell scripts (lib/windows/)
config/         Per-environment profiles (config/*.env, gitignored; *.env.example committed)
src/            SdtdTestPilot mod source
tests/          SdtdTestPilot.Tests (xUnit, engine-free)
mod/            ModInfo.xml for SdtdTestPilot's packaged output
docs/           overview, runbook, lessons-learned, HeadlessTestDriver protocol reference
output/         Per-profile build artifacts and run results (gitignored)
```
