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

### Persistent save vs. throwaway save

By default the run reuses the profile's persistent save (`GAME_SAVE_NAME`). That is fast
and closer to a real long-lived server, and the pipeline already resets visit history
between runs.

What it does *not* reset is the player. If a run leaves the character dead - a teleport
into a bad spot will do it - that death is saved, and no console command brings them back
(see `docs/lessons-learned.md`). For a guaranteed-clean starting point:

```bash
./bin/run-roundtrip.sh --profile v3 --fresh-save
```

This switches `sdtdserver.xml`'s `GameName` to a throwaway `<GAME_SAVE_NAME>Fresh<UTC timestamp>`
for the run, so the player starts fresh and alive with no visit history. Teardown restores
the config and deletes the save. Add `--keep-save` to keep it for post-mortem inspection
(you then have to delete it yourself).

`WorldGenSeed` is deliberately left alone, so the already-generated terrain is reused.
Regenerating terrain costs tens of minutes and several GB per run and buys no additional
determinism - the save slot is what carries player and visit state.

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

- **Discord login prompt**: handled automatically - no manual step needed.
  `04-launch-client.sh` disables Discord in the registry (under
  `HKCU\Software\The Fun Pimps\7 Days To Die`) before launching, and `07-teardown.sh`
  restores the previous state. Without it, Discord's `MainMenuOpening` handler suppresses
  the vanilla main menu and `MainMenuTrigger` never fires, which looks exactly like a
  generic hang. See `docs/lessons-learned.md` for the mechanism and for why no launch
  argument can do this instead.

  Worth knowing: v3.x and v2.6 store this setting in *different* registry values, and the
  registry key is shared by every 7DTD install on the machine, so a v3 run used to leave
  the v26 profile hanging on its next run (v3.x deletes the value v2.6 reads). Both
  formats are now written every run, so the order you run profiles in doesn't matter.

  The one caveat: the registry write lands in the HKCU hive of the SSH user, while the
  client runs as `OMEN_USER_ID`. Those are the same account today, and the script fails
  loudly if they ever diverge - if you see that error, run the pipeline as the same
  Windows account the client runs as.

## Troubleshooting

If a run leaves things in a bad state (killed mid-run, `run-roundtrip.sh`'s process was
force-killed so its `EXIT` trap never fired), run `./bin/07-teardown.sh <profile>`
manually - every step in it is safe to re-run and skips gracefully if there's nothing to
restore.
