# Overview

## What this is

Two independent pieces that happen to live in one repo because they were built
together and are usually used together:

1. **`SdtdTestPilot`** - a 7DTD mod, entirely separate from any mod under test. On
   startup it either connects to a remote dedicated server or hosts a local world
   (`-testpilot.mode=connect|hostload`), waits for the world to be playable, then opens
   a local-file command queue that an external driver can push console commands into
   and read results back from. See `docs/HeadlessTestDriver.md` for the exact protocol
   and the game APIs it uses (all public, no reflection/patching).

2. **The `bin/`/`lib/` orchestration scripts** - a pipeline that runs *around*
   `SdtdTestPilot` to make a specific test repeatable: spin up a disposable Docker
   server, build+deploy Debug mod binaries, drive the client through a scenario via the
   command queue, check the result against server-side save data, then restore
   everything.

## Why the dialog is driven through the real UI, not a stand-in

The roundtrip scenario (`05`) calls the mod's service layer directly, which keeps it fast
and independent of the UI - but it also means the part of the mod a player actually looks
at was never executed. Everything in `DialogPatches.cs` (paging, response text, the status
header, the XUi binding) ran zero times during a green run.

The dialog scenario (`05b`) closes that by opening the game's own dialog window group and
activating responses the same way a click does, rather than reimplementing the flow. That
choice matters: a stand-in that calls `GetResponses` itself would verify the mod's logic
while quietly skipping the layer where the logic meets the game - which is exactly where
the interesting failures live (a response list with fewer slots than entries, a statement
the skin doesn't render, a localization key that resolves in code but not in the UI).

Two things follow:

- **Assertions cover what is decidable; screenshots cover the rest.** Paging boundaries,
  dropped entries and unresolved keys are checked mechanically. Clipping, wrapping and
  layout are not decidable from data, so the run keeps images instead and leaves the
  judgement to a human.
- **The test harness lives in the mod under test, the generic parts here.** `vtttest
  dialog` needs `VisitedTraderTeleport`'s internals, so it ships there (Debug-only);
  screenshots are useful to any mod, so `testpilot screenshot` lives in `SdtdTestPilot`.

## Why each run starts from known state

Early versions of this tool reused whatever world the Docker server already had. Two
problems came from that:

- `VisitedTraderTeleport`'s destination canonicalization merges a new trader visit into
  an *existing* recorded destination when it falls within an already-recorded trader
  area. On a world with leftover visit history from earlier runs, a "new" `vtttest
  record` could silently attach to a stale key instead of the trader actually visited -
  making the whole test non-deterministic depending on what a *previous* run happened
  to leave behind.
- A test scenario that teleports the player to a random already-visited destination can
  land them in an unrelated, possibly zombie-infested part of the map. A player death
  there persists in the save and carries over into the *next* run.

`03-deploy-mods.sh` resets `VisitedTraderTeleportData.json` before every run (backed up
and restored by `07-teardown.sh`), and the default scenario only ever spawns and visits
traders right next to the player's current position - so results don't depend on the
world's history, and there's no reason for the player to end up somewhere dangerous.

For a *genuinely* clean run - a new player character too, not just reset visit history -
use `run-roundtrip.sh --fresh-save`. It switches `sdtdserver.xml`'s `GameName` to a
throwaway save for the run and puts everything back afterwards.

Note what it deliberately does *not* touch: `WorldGenSeed`. `GameName` selects the save
slot, which is what carries player state and visit history, so switching it alone gets the
full benefit. `WorldGenSeed` selects the terrain, and changing it forces a full RWG
generation costing tens of minutes and several GB per run for no added determinism.

## Why GAME_SAVE_NAME instead of "find the newest save file"

The Docker server's `Saves` directory accumulates data from every world ever tested on
that machine, not just the one the current profile is using. Finding
`VisitedTraderTeleportData.json` by "most recently modified" is unsafe: if the current
profile's world hasn't produced that file yet (e.g. its very first run), the search
silently falls back to some *other*, unrelated world's file - which was then backed up,
cleared, and (if everything else went fine) restored, but with a real risk of touching
data that had nothing to do with the run in progress. `GAME_SAVE_NAME` pins the search
to a `<world>/<GAME_SAVE_NAME>/VisitedTraderTeleportData.json` path where only the
world-name segment (unpredictable for RWG worlds) is a wildcard.

## Why bash on the Linux side, PowerShell over SSH for the Windows side

The Docker server and orchestration run on this machine directly. The game client only
runs on Windows, so anything client-side (mod deployment, launching the client,
submitting queue commands) goes through `ssh <host> powershell.exe ...`. See
`docs/lessons-learned.md` for the quoting/argument-passing pitfalls this created.

## Extending to a different mod

`bin/05-run-scenario.sh` and `bin/06-verify.sh` are the only VisitedTraderTeleport-aware
pieces. Everything else - `SdtdTestPilot` itself, the build/deploy/launch/teardown
stages, the command-queue library (`lib/testpilot-queue.sh`) - works with any mod that
exposes console commands. To test a different mod, replace those two scripts (and the
`vtttest`-specific parts of `config/*.env`, e.g. `VTT_MOD_DISPLAY_NAME`,
`VTT_CLIENT_MOD_DIRNAME`) with equivalents for that mod's own test surface.
