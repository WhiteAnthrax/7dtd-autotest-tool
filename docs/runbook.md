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
5. **Make sure the account running this harness owns the server's `data/` tree.** The
   pipeline rewrites `sdtdserver.xml` (throwaway saves), creates `Mods/SdtdTestPilot/`
   and removes it again, so read access is not enough:

   ```
   ls -ld <DOCKER_COMPOSE_DIR>/data/serverfiles          # should be owned by you
   sudo chown -R "$(id -u):$(id -g)" <DOCKER_COMPOSE_DIR>/data   # if it is not
   ```

   The compose files pass `UID/GID=1000`, so the container keeps working afterwards. Skipping
   this shows up as `01-start-server.sh ... sed -i ... (exit 4)`, which is `sed` failing to
   write the config rather than anything to do with the save.

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
./bin/05b-run-dialog-scenario.sh v3  # walk the real trader dialog, capture screenshots
./bin/06-verify.sh v3            # check the scenario result against server data + the dialog
./bin/07-teardown.sh v3          # restore both mods + visit history, stop client, stop server
```

`04-launch-client.sh` also takes `CLIENT_LANGUAGE` as an environment variable, which
becomes the game's `-language=` launch argument:

```bash
CLIENT_LANGUAGE=german ./bin/04-launch-client.sh v3
```

The stages take only a profile name, so `--fresh-save`/`--keep-save` (which
`run-roundtrip.sh` parses) reach them as environment variables instead:

```bash
TESTPILOT_FRESH_SAVE=1 ./bin/01-start-server.sh v3   # throwaway save, as --fresh-save
TESTPILOT_KEEP_SAVE=1 ./bin/07-teardown.sh v3        # keep it, as --keep-save
```

`01-start-server.sh` is the only stage that reads `TESTPILOT_FRESH_SAVE` (it is what
rewrites `GameName`); the later stages pick the save up from the state file it writes, so
they need no environment of their own.

`05b` depends on `05`: it reuses the trader `05` already spawned and recorded, so the
dialog walkthrough doesn't add a visit of its own and change the data `06` checks.

`output/<profile>/` accumulates build artifacts (`*.debug.dll`, `mod-config/`), backups
(`server-mod-backup/`, `server-data-backup.json`), and results
(`scenario-result.json`, `dialog-result.json`, `verify-result.json`, `screenshots/`) -
useful for post-mortem inspection. `07-teardown.sh` doesn't delete this directory, only
the client-side scratch/queue dirs on the Windows host.

### Screenshots as evidence

`05b-run-dialog-scenario.sh` captures what the client actually drew at each step into
`output/<profile>/screenshots/<language>/`, where `<language>` is the language the game
reported using (not the one it was asked for - see the sweep below):

| File | Shows |
|---|---|
| `01-dialog-start.jpg` | The trader's opening screen with the mod's travel option. |
| `02-destinations-page1.jpg` | Destination list, page 1 of 2 (5 entries + a next-page row). |
| `03-destinations-page2.jpg` | Page 2 (the remaining 2 entries + a previous-page row). |
| `04-destinations-page1-again.jpg` | Back on page 1, to show paging back works. |

These are the one thing the assertions cannot cover: text that is clipped, wrapped or
pushed out of the panel is still perfectly correct data. Look at them when changing any
response text, and especially after a localization change - German and Russian run
noticeably longer than English.

The images come from `GameUtils.TakeScreenShot`, which reads the framebuffer after
`WaitForEndOfFrame` and so includes every open UI window. They are JPEGs because that is
what the game writes; the game appends the extension itself, which is why the console
command takes a path *without* one.

Expect two solid black rectangles in the top-right corner of every capture. They are in
the vanilla HUD area, appear identically in shots taken before the mod's dialog is ever
opened, and are a known artifact of reading the framebuffer this way (that read doesn't
pick up separately-rendered textures). Nothing to do with `VisitedTraderTeleport` - don't
spend time chasing them.

## Checking every language

```bash
./bin/run-language-sweep.sh --profile v3 --fresh-save               # all 13 languages
./bin/run-language-sweep.sh --profile v3 --languages german,russian # just these
```

Prefer `--fresh-save` here. A sweep is half an hour of idle player, and if a previous run
left the character dead that death is in the save - which now fails *every* language,
because the walkthrough asserts the player is alive and nothing revives them.

Watch for `LANGUAGE_SWEEP_RESULT {"profile":"v3","status":"ok","ok":true,"failed":[]}`.

The game reads `-language=<name>` once at startup, so each language means relaunching the
client - roughly three minutes per language on top of the usual setup. The names are the
column names from the mod's `Localization.csv`: `english`, `german`, `spanish`, `french`,
`italian`, `japanese`, `koreana`, `polish`, `brazilian`, `russian`, `turkish`, `schinese`,
`tchinese`.

Per language the sweep keeps `screenshots/<language>/`, `dialog-<language>.json` and
`verify-<language>.json`, plus one `language-sweep-result.json` summarising all of them.
A failed language does not stop the sweep - knowing which ones are broken beats stopping
at the first.

Two assertions matter most here and both are mechanical:

- **The client honoured the language it was given.** A client that silently falls back
  still passes every other check, so the run would certify text nobody ever looked at.
  `06-verify.sh` compares the requested language against the one the game reports.
- **No raw `vtt_*` key reached the screen.** That is what a missing translation cell looks
  like from the outside.
- **The player was alive and stood still the whole time.** A sweep leaves an idle player
  in the open world for half an hour; one that gets killed respawns somewhere else, which
  re-orders the distance-sorted destination list and puts the respawn UI over every
  screenshot afterwards - while the dialog data stays perfectly correct. The sweep runs
  `killall` and `settime day` before each pass to make that unlikely, and `06-verify.sh`
  fails the run if it happens anyway.

What the assertions can't see is length. German and Russian run noticeably longer than
English, and clipped or wrapped text is still perfectly correct data - so look at the
screenshots after any change to response text or to the `Localization.csv`.

Only `04`, `05b` and `06` repeat per language. `03-deploy-mods.sh` and
`05-run-scenario.sh` deliberately run once; `docs/lessons-learned.md` explains why
re-running them inside one sweep is unsafe.

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

## The server updates itself; the client doesn't

The Docker server runs `startserver-with-update.sh`, so **it picks up new 7DTD releases on
every start**. The Windows client is a pinned copy that only changes when someone updates
it. They drift apart on their own, and a mismatched client shows a version dialog and
never connects - which, from the pipeline's side, looks exactly like any other hang.

`04-launch-client.sh` compares the two compatibility versions right after launching and
fails immediately with both numbers if they differ, rather than sitting in the READY wait
for `READY_TIMEOUT_SECONDS` and then reporting nothing useful. If you see that error:

- **Update the client** to match the server. For a 7D2D Mod Launcher instance, update it
  from the launcher; for a plain copy of the Steam install, re-copy it after Steam
  updates.
- **Or pin the server.** The compose project takes `STEAM_BETA` (see its
  `docker-compose.yml`), and the update itself comes from `startserver-with-update.sh` -
  point the service at `startserver.sh` instead if you want it to stay put. That is the
  server owner's call, not this tool's, so nothing here changes it for you.

Only a *confirmed* mismatch is fatal. If either version can't be read the run logs a
warning and continues, so this check can't block an otherwise-fine run.

## Verifying a change

```bash
shellcheck -x bin/*.sh lib/*.sh   # same check CI runs; -x follows the sourced lib/*.sh
pre-commit install                # once per clone: runs shellcheck + gitleaks on commit
```

The unit tests need the .NET SDK, which the Linux orchestration host does not necessarily
have (`dotnet` is not installed on the current one - the mods themselves are built on the
Windows host by `02-build-mods.sh`). Where they do run:

```bash
dotnet test tests/SdtdTestPilot.Tests/SdtdTestPilot.Tests.csproj -c Release
```

CI (`.github/workflows/tests.yml`) runs exactly that on every push, so pushing a branch is
a perfectly good way to run them. They only cover the engine-independent
`SdtdTestPilot.Core` bits, so anything touching the pipeline itself still deserves a real
`./bin/run-roundtrip.sh --profile v3`.

## Verifying a release package

The roundtrip and the language sweep run against a **Debug** build. They have to: `vtttest`
and `vtttest dialog` only exist when `VTT_TEST_HARNESS` is defined, and
`VisitedTraderTeleport.csproj` defines it only for `Configuration=Debug`. What ships is a
Release build with no harness in it, so a green sweep says nothing about the packaged zip
on its own.

Build the ZIP with the script rather than by hand, so which commit it came from is recorded:

```bash
./bin/build-release-package.sh --profile v3            # builds VTT_BRANCH's tip
./bin/build-release-package.sh --profile v26 --ref v26-work
```

It writes `output/<profile>/dist/VisitedTraderTeleport-<version>.zip` plus a
`.provenance.json` naming the commit, and refuses to build a local branch that is behind its
remote - which is how a v2.6 package once got built from the commit *before* its release
commit, minutes after the PR was merged, because only the other line had been pulled.

Then run this on the ZIP before publishing it:

```bash
./bin/run-release-verification.sh --profile v3 \
    --package output/v3/dist/VisitedTraderTeleport-0.7.11.zip \
    --languages german,japanese --fresh-save
```

Watch for `RELEASE_VERIFICATION_RESULT {... "packaged_config":"identical","ok":true ...}`.

The result file records the ZIP's `sha256` and, from the provenance sidecar, the commit it
was built from; `bin/publish-to-nexus.sh` refuses to upload a file whose hash does not match
it. Rebuilding a package without re-verifying it is
therefore caught rather than assumed: the version number stays the same across a rebuild,
so the name alone never proved anything.

It installs the ZIP on the server and client in place of the Debug build and drives it from
`SdtdTestPilot`, which is a separate mod and therefore works against any build of the mod
under test. What it renders is checked per language; what it *does* is checked once each,
after the languages, and every one of those stages is part of the verdict - `ok` is false if
any of them fails:

- **What it renders**, per language: the travel option is offered, the destination list has
  the expected entries, nothing the mod produced was dropped before it reached the screen,
  no raw `vtt_` key leaked through, the client honoured the requested language, and the
  player stayed alive and still. Screenshots land in
  `output/<profile>/screenshots/<language>/`.
- **What it does**, once: a real trip, chosen from the dialog exactly the way a player picks
  it. The verdict comes from the *server* rather than from the build reporting on itself -
  `VisitedTraderTeleportService` logs `Teleported` on success and `Teleport failed:`
  otherwise, so the run asserts one `Teleported`, no failure, no exception, the visit
  records still in the save, and the player alive at the end. Screenshots in
  `output/<profile>/screenshots/travel/`.

- **Who it takes along**: a hired companion and a placed turret are put next to the player
  and marked the way the game marks them (`testpilot mark hired|owned`); the companion has to
  move with the player and the turret has to stay - issue #21.
- **A real distance**: a trip of 1000m, so the destination has to be prepared rather than
  being terrain already under the player's feet. This is the only stage that exercises the
  preparation and transport machinery at all.
- **More than one page** of destinations, walked to the end and back.
- **A trip that costs something**: with nothing to pay with it must be refused and take
  nothing; with enough it must cost exactly the configured amount and ask for confirmation
  first. This one restarts the world with the cost setting on, and so runs last.

All of that covers the dedicated-server topology only, because that is what this script
starts. Travel takes a different branch for a local player (`if (player is EntityPlayerLocal)`
in VisitedTraderTeleportService), so the single-player path needs its own runs before a
release:

```bash
for s in companion distance paging cost; do
    ./bin/run-scenario-check.sh --scenario "$s" --profile v3 --mode hostload \
        --package output/v3/dist/VisitedTraderTeleport-0.7.11.zip
done
```

That travel part is what a screenshot cannot reach: the store, key canonicalization, travel
readiness and cost logic all moved into `VisitedTraderTeleport.Core` between 0.7.9 and
0.7.10, and a localization release can quietly carry that kind of change.

It also compares the packaged `Config/` against `output/<profile>/mod-config/` - the copy
the sweep actually deployed - byte for byte, and fails the run if they differ. That
comparison is what carries the sweep's result over to the release: the translations live
entirely in those files and the DLL only looks keys up. (Compare against the deployed copy,
never `git show`, whose LF form differs from the CRLF packaged one.)

Paging and long-distance travel used to be listed here as things it does not cover. They now
have scenarios of their own, run through `bin/run-scenario-check.sh`:

```bash
./bin/run-scenario-check.sh --scenario distance --profile v3   # 1000m trip, both topologies
./bin/run-scenario-check.sh --scenario paging   --profile v3   # seven destinations, two pages
./bin/run-scenario-check.sh --scenario companion --profile v3  # issue #21
./bin/run-scenario-check.sh --scenario cost      --profile v3   # travel cost + confirmation
./bin/run-scenario-check.sh --scenario forget    --profile v3   # removing a destination
```

**distance** is the one that matters most. Every other travel scenario spawns its traders at
the player's feet, so the destination is already loaded and the mod skips preparation
entirely - a 0m trip logs `Teleported` and nothing else. This one records a trader, moves the
player 1000m away (`TRAVEL_DISTANCE` to change it), and travels back, so `Preparing
destination` / `Destination ready after preparation` actually run and are asserted, along
with no queue expiry, no `Destination was not ready`, and a player who is still alive at the
far end.

**cost** switches `<TravelCost>` on in the *installed* config (03c, which has to run before
the client starts - the mod reads that file at world load and there is no reload) and then
travels twice: once with nothing to pay with, which must be refused without taking anything,
and once after `testpilot inventory give`, which must cost exactly the configured amount. It
also covers the confirmation screen, which only appears when a trip costs something and so
has never been rendered by any other scenario. `COST_ITEM` / `COST_PER_METER` /
`COST_MINIMUM` change the terms; the default charges a floor of 7 casino tokens so the
expected number does not depend on the distance.

**forget** covers issue #58 - a destination could be recorded but never removed. It records
three traders, forgets one through the dialog, and checks that it is gone from the list *and*
from the save, that the other destinations are untouched, that backing out of the confirmation
removes nothing, and that visiting the trader again brings it back. That last one is what
makes the feature a tidy-up rather than data loss.

**paging** records seven destinations - four different traders where the player stands, then
three more 400m away, because traders near each other share one destination key - and walks
the two pages, checking that nothing is duplicated or dropped between them and that the
page controls are localized.

## Checking who travel takes along

```bash
./bin/run-companion-check.sh --profile v3
```

Watch for `COMPANION_CHECK_RESULT {... "status":"ok" ...}`.

It spawns a stand-in companion and a turret, marks them the way SCore and a placed turret
mark theirs, travels, and checks that the companion was gathered and the turret was not.
Those are the two halves of the same rule and they pull in opposite directions - a companion
left behind is a regression, a turret dragged out of a base is issue #21 - so both are
asserted in one run.

`--fresh-save` is the default here, unlike the other drivers: the scenario needs a living
player and asserts it at both ends.

Run it **both ways**:

```bash
./bin/run-companion-check.sh --profile v3                     # dedicated server + client
./bin/run-companion-check.sh --profile v3 --mode hostload     # the client hosts the world
```

That is not thoroughness for its own sake. Travel takes a different branch for a local player
than for a remote one (`if (player is EntityPlayerLocal)` in `VisitedTraderTeleportService`),
and each branch has its own `GatherCompanions` call site with a different centre. A
dedicated-server run leaves the single-player path untested and vice versa.

**Everything about the entities happens where the world lives**, through
`lib/world-console.sh`, and that is not incidental: with a dedicated server that is the
server process, and in hostload it is the client. `GatherCompanions` runs where the world is,
so an entity spawned or marked on the other side is invisible to the code under test - see
`docs/lessons-learned.md` for the several wrong answers that came from getting this wrong.
The probe is taken on both sides and both are recorded, so a marker written to the wrong
process shows up as a disagreement rather than as a product bug. (In hostload they are the
same process and simply agree.)

The same applies to the game's own log, which is the load-bearing evidence that a gather
happened: the dedicated server writes `output_log__*.txt` next to its files, while a hosting
client writes Unity's `Player.log` under `AppData\LocalLow\The Fun Pimps\7 Days To Die`.
`world_log_grep_count` picks the right one; reading the wrong one is silent, and showed up
as a run that counted zero gathers while the companion had visibly been moved.

If the scenario fails it captures what the client was showing at the time into
`output/<profile>/screenshots/companion/failure.jpg`. Most failures here are about what the
game was doing - a dead player, a spawn that landed badly - rather than about the numbers.

## Running a console command on the server

`lib/server-console.sh` exists because `lib/testpilot-queue.sh` talks to the *client*. Both
take a console command and return text, which is exactly why they are separate names rather
than one helper with a flag.

```bash
source lib/server-console.sh
server_console_checked "le" "Total of"
```

The second argument is a substring to wait for; without it the call waits out the full
timeout, because the console answers asynchronously and there is nothing to block on. A
fixed sleep was tried first and cut off replies at two seconds.

The route is `docker exec` into the container and then telnet to loopback: with
`TelnetPassword` empty - the shipped default - the server binds telnet to loopback only, so
the published port accepts connections from this host and reaches nothing.

## Publishing a verified package to Nexus Mods

### The ids for this mod

Public, and awkward to re-derive, so they are written down here. Note the mod id is **not**
the number in the page URL:

| | value |
|---|---|
| `--mod-id` | `4548370376889` (the page URL's `10425` is the *game-scoped* id) |
| `--file-id`, 3.x line | `7599716` - "Travel Between Visited Traders (V3.0)", category `main` |
| `--file-id`, v2.6 line | `7403906` - "VisitedTraderTeleport 0.2.0", category `optional` |

A third file (`7542863`) exists but is inactive and unused - leave it alone.

To re-derive them, or for a different mod:

```bash
. ~/.config/nexus-upload.env
H=(-H "apikey: $NEXUS_API_KEY" -H "User-Agent: 7dtd-autotest-tool")
curl -sS "${H[@]}" https://api.nexusmods.com/v3/games/7daystodie/mods/<page url number> | jq .data.id
curl -sS "${H[@]}" https://api.nexusmods.com/v3/mods/<that id>/files | jq .data.mod_files
curl -sS "${H[@]}" https://api.nexusmods.com/v3/mod-files/<file id>/versions | jq -r '.data.versions[] | "\(.version) \(.category)"'
```

### Publishing

One command per line. It does the whole thing: builds the package from the branch tip, runs
the release gate against it, creates the GitHub release, uploads to Nexus as a new version of
the existing file, and reads the page back to check it came out clean.

```bash
./bin/release.sh --line v3 --dry-run   # rehearse: preflight + what would be published
./bin/release.sh --line v3             # 3.x line, from main
./bin/release.sh --line v26            # v2.6 line, from v26-work
```

Everything that used to be typed by hand now comes from `config/release-lines.conf` or from
the mod repo at the commit being released:

| | where it comes from |
|---|---|
| version, tag | `mod/VisitedTraderTeleport/ModInfo.xml` at that commit |
| release notes | that version's section of `CHANGELOG.md`, plus the line's header |
| "use the other release instead" | the *other* branch's ModInfo.xml, so it is never stale |
| Nexus changelog | `docs/NexusModsChangelog-<version>.txt` at that commit |
| file id, category, display name | `config/release-lines.conf` |

Preflight runs before anything is built, because finding out that a changelog is missing after
a twenty-minute verification is a waste of an evening: the branch has to match origin, `gh`
has to be logged in, the API key has to be readable, both changelog forms have to exist, and
the tag must not already be released.

`--dry-run` keeps an existing package rather than rebuilding (two builds of one commit are not
byte-identical, and replacing the verified ZIP with an unverified twin is exactly the trap
this pipeline already fell into once) and skips the gate.

`--skip-verify` publishes without re-running the gate, and only works when a passing
verification exists **for those exact bytes** - the check is on the sha256, not the filename.

Afterwards it runs:

```bash
./bin/check-nexus-page.sh --mod-id 4548370376889
```

which reads every file on the page and complains if two versions of one file are current, if
the newest version is retired while an older one is not, or if two *files* are current in the
same category.

The first of those is not hypothetical. **`main` is exclusive; `optional` is not.** Nexus
retires the previous main version by itself, so the 3.x file looks after itself - but the
v2.6 file kept 0.6.22 listed as current next to 0.6.23, and it had to be set to Old by hand.
`bin/publish-to-nexus.sh` now sends `previous_version_id` (the version the new one replaces,
looked up automatically; `--no-supersede` turns it off), which is the only handle the API
offers: there is no endpoint for changing a version's category afterwards.

When the check does complain, the fix is on the site: the mod's edit page, Files step, the
file's ⋮ menu, and set the older version to Old version.

What this still does **not** do, because the Upload API does not expose it: create a mod page,
edit the Full description, or change tags.

### Testing a deliberate version mismatch

`VTT_SERVER_RELEASE_PACKAGE` deploys a different build to the server than to the client, so
a client/server mod mismatch can be produced on purpose:

```bash
VTT_RELEASE_PACKAGE=<new zip> VTT_SERVER_RELEASE_PACKAGE=<old zip> ./bin/03-deploy-mods.sh v3
```

This is the only way to find out what the game does about one, and what it does is not
obvious - see `docs/ProtocolVersioning.md` in the mod repo. Briefly: package ids are
negotiated by *name* at connect, a client that does not know one of the server's types is
denied entry outright, and the connect-time CRC does not cover mod files at all.

Both sides log `Registered ... as net package id` at startup. Those are the mod registering
itself and are **overwritten at connect** by the server's table, so a difference there means
nothing on its own.

### Testing a branch

Profile settings can be overridden from the environment for one run:

```bash
VTT_BRANCH=feature/my-change ./bin/run-scenario-check.sh --scenario forget --profile v3
```

Only the variables in `PROFILE_OVERRIDABLE_VARS` (`lib/common.sh`) work this way -
`VTT_BRANCH` and `CLIENT_LANGUAGE`. Everything else in the profile wins, deliberately: a
half-overridden environment is harder to reason about than one that is either the profile or
an explicit exception to it.

This matters more than it looks. `load_profile` sources the profile, so before this existed
an environment variable was silently overwritten by it - a run launched to test a feature
branch quietly tested `main` instead, and the only sign was that the feature "did not work".

### The ids, and doing it by hand

`config/release-lines.conf` holds them, and they are public. To re-derive them, or to publish
a single step by hand, the underlying scripts still work on their own:

```bash
./bin/build-release-package.sh --profile v3 --ref main
./bin/run-release-verification.sh --profile v3 --package output/v3/dist/VisitedTraderTeleport-0.7.11.zip --fresh-save
./bin/publish-to-nexus.sh --profile v3 --package ... --version 0.7.11 --file-id 7599716 \
    --mod-id 4548370376889 --display-name "..." --changelog ... --update-mod-version
```

## Troubleshooting

If a run leaves things in a bad state (killed mid-run, `run-roundtrip.sh`'s process was
force-killed so its `EXIT` trap never fired), run `./bin/07-teardown.sh <profile>`
manually - every step in it is safe to re-run and skips gracefully if there's nothing to
restore.

**A stale `output/<profile>/fresh-save-name.txt`.** That file is how stages after
`01-start-server.sh` know to use a throwaway save. It is written by `01` and removed by
`07` - so a `--fresh-save` run killed between the two leaves it behind (as does
`--keep-save`, deliberately). Running a later stage on its own after that makes it look
for a save that may no longer exist:

```
no VisitedTraderTeleportData.json found under ... for save name 'AutotestSafeFresh2026...'
```

Delete the file to go back to the profile's persistent save. A full `run-roundtrip.sh`
needs no cleanup either way - `01` clears it at the start of every run.

**`--fresh-save` fails immediately on a server whose config you don't own.**

```
ERROR: bin/01-start-server.sh:53 failed (exit 4): sed -i -E "s|(<property name=\"GameName\"...
```

`--fresh-save` rewrites `GameName` in the server's `sdtdserver.xml` for the run, so the
account running the pipeline has to be able to write that file. Compose projects differ:
one may leave `serverfiles/` owned by your user, another by the container's uid, and
`sdtdserver.xml` is mode 644/755 either way - so the same flag works for one profile and
not another. Check with `ls -l <DOCKER_COMPOSE_DIR>/data/serverfiles/sdtdserver.xml`.

Without it, run against the profile's persistent save. That is fine for a roundtrip, and
for a language sweep it just means the player has to survive the run on their own - which
`06-verify.sh` checks rather than assumes.
