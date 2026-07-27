# Runbook

## Prerequisites

- `docker`, `docker compose`, `jq`, `git`, `ssh`, `scp`, `shellcheck` on this machine.
- `ssh <OMEN_SSH_HOST>` works non-interactively (key auth set up in `~/.ssh/config`).
- The Windows host has the .NET SDK on PATH as `dotnet`, and a 7DTD client install.
- An existing Docker Compose project for a 7DTD dedicated server on this machine, with
  `VisitedTraderTeleport` already installed in its `Mods/` folder (Release build is
  fine - `03-deploy-mods.sh` overwrites it with a Debug build for the run and restores
  the original afterward).

## One-time setup

1. `cp config/v3.env.example config/v3.env` (and/or `v26.env.example` -> `v26.env`).
2. Edit the new file: at minimum set `OMEN_USER_ID` to the Windows account name the
   scheduled task should run as, and confirm every path matches your environment.
3. **Point the server at a dedicated test world**, not one you're playing on manually:
   edit `sdtdserver.xml` on the Docker server -
   `GameName` and `WorldGenSeed` -> some value not used elsewhere (e.g.
   `AutotestSafe`), `WorldGenSize` -> `6144` (fastest to generate). Set
   `GAME_SAVE_NAME` in `config/<profile>.env` to the same `GameName` value.
   First boot against a new seed generates a fresh world - this can take several
   minutes (5+ observed for the v2.6 + The Wasteland line). Subsequent runs reuse it
   and load in under two minutes.
4. Restart the server once (`docker compose restart <service>` from
   `DOCKER_COMPOSE_DIR`) and confirm in its log that the new world actually starts
   (`grep 'StartGame done' <newest output_log__*.txt>`).

## Running the full pipeline

```bash
./bin/run-roundtrip.sh --profile v3
```

Watch for the final line: `ROUNDTRIP_RESULT {"profile":"v3","status":"ok",...}`.
`status` is `"ok"` on success, or `"<stage> failed"` naming the stage that broke.
Teardown always runs, even on failure (it's wired to `run-roundtrip.sh`'s `EXIT` trap).

## Running stages individually (for debugging)

Each stage is a standalone script; run them in order with the same profile:

```bash
./bin/01-start-server.sh v3      # start the Docker server, wait for it to be playable
./bin/02-build-mods.sh v3        # Debug-build VisitedTraderTeleport + SdtdTestPilot on Windows
./bin/03-deploy-mods.sh v3       # back up + deploy both mods, reset visit history, restart server
./bin/04-launch-client.sh v3     # launch the client (scheduled task), wait for READY
./bin/05-run-scenario.sh v3      # drive the vtttest scenario through the command queue
./bin/06-verify.sh v3            # cross-check the scenario result against server-side data
./bin/07-teardown.sh v3          # restore both mods + visit history, stop client, stop server
```

`output/<profile>/` accumulates build artifacts (`*.debug.dll`), backups
(`server-mod-backup/`, `server-data-backup.json`), and results
(`scenario-result.json`, `verify-result.json`) - useful for post-mortem inspection.
`07-teardown.sh` doesn't delete this directory, only the client-side scratch/queue dirs
on the Windows host.

## Known manual steps

- **Discord login prompt**: if the Windows account's Discord is linked in a way that
  triggers a login prompt on the game's main menu, the client hangs indefinitely
  waiting for it - `SdtdTestPilot` cannot dismiss it. Disable Discord integration once
  in the game's own Options on that machine (Player.log will show
  `[Discord] Saving settings with DiscordDisabled=True` after doing so). See
  `docs/lessons-learned.md` - a command-line way to disable this ahead of time hasn't
  been found yet.

## Troubleshooting

If a run leaves things in a bad state (killed mid-run, `run-roundtrip.sh`'s process was
force-killed so its `EXIT` trap never fired), run `./bin/07-teardown.sh <profile>`
manually - every step in it is safe to re-run and skips gracefully if there's nothing to
restore.
