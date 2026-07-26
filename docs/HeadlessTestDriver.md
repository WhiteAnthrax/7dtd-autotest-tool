# Headless Test Driver (SdtdTestPilot)

`SdtdTestPilot` is a separate, test-only mod (not part of `VisitedTraderTeleport` and not
shipped with it) that removes the last manual step in headless testing: getting a game
*client* into a running world without a human clicking through the main menu. It auto-connects
to a remote server, or auto-hosts a local world, on startup, then lets an external driver
script inject arbitrary console commands (including `VisitedTraderTeleport`'s own `vtttest`,
see `docs/GameBehaviorTesting.md`) through local files and read back the results.

**Never install this mod on a real or public server, and never ship it.** It exists purely to
let a driver script run a client non-interactively. See "Safety" below.

## Building

`SdtdTestPilot` only does anything at runtime in a `Debug` build (`TESTPILOT_ENABLED` is
defined only when `Configuration=Debug`, see `src/SdtdTestPilot/SdtdTestPilot.csproj`). A
`Release` build compiles down to an `IModApi` implementation that logs one line and returns.

This mod is not built by `devtools/Invoke-WindowsBuild.ps1` (that script is scoped to
`VisitedTraderTeleport` only). Use the dedicated script instead:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File devtools\TestPilot\Invoke-TestPilotBuild.ps1 `
    -GamePath 'D:\GAMES\7D2D\Custom\3.0Vanilla' `
    -ClientModsDir 'D:\GAMES\7D2D\Custom\3.0Vanilla\Mods'
```

`-ClientModsDir` is optional; omit it to just build and run the unit tests
(`tests/SdtdTestPilot.Tests`).

## Enabling it at runtime

Even in a Debug build, `SdtdTestPilot` does nothing unless **both** of the following are true:

1. A marker file sits next to the mod DLL:
   ```
   Mods/SdtdTestPilot/EnableTestPilot.txt   (empty file, contents don't matter)
   ```
2. A valid `-testpilot.mode=...` command-line argument is supplied at launch (see below).

Either one missing means the mod is inert — no connection attempt, no file I/O beyond the
marker-file check itself.

## Command-line arguments

Parsed independently of the game's own `GameStartupHelper`/`LaunchPrefs` system, via a
`-testpilot.` prefix so it can never collide with a real launch pref or game pref (unknown
`-key=value` arguments are logged and ignored by the game, not treated as fatal — confirmed by
decompiling `GameStartupHelper.ParseCommandLine`, which calls `ParsePref(..., _quitOnError:
false, ...)` for every argument it doesn't recognize).

| Argument | Required for | Meaning |
|---|---|---|
| `-testpilot.mode=connect\|hostload` | always | Selects the mode. Omitted/unrecognized ⇒ disabled. |
| `-testpilot.queue=<dir>` | always | Base directory for the command queue (see below). |
| `-testpilot.ip=<ip>` | `connect` | Server IP to join. |
| `-testpilot.port=<port>` | `connect` | Server port (1–65530). |
| `-testpilot.password=<pw>` | `connect`, optional | Server password, if any. |
| `-testpilot.world=<world>` | `hostload` | World name to load (e.g. `Navezgane`). |
| `-testpilot.gamename=<name>` | `hostload` | Save-game name to load/create. |
| `-testpilot.pollms=250` | optional | Command queue poll interval in milliseconds. |
| `-testpilot.readytimeout=120` | optional | Seconds to wait for the world/player to become ready before giving up. |

Also pass the game's own `-SkipNewsScreen=true` launch pref alongside `-testpilot.*` (see
"Other dialogs that block startup" below) — without it, the game blocks on the news screen
before `SdtdTestPilot` ever gets a chance to run.

Example (remote):
```
7DaysToDie.exe -SkipNewsScreen=true -testpilot.mode=connect -testpilot.ip=192.168.1.50 -testpilot.port=26900 -testpilot.queue=D:\testpilot-queue
```

Example (local, no server needed):
```
7DaysToDie.exe -SkipNewsScreen=true -testpilot.mode=hostload -testpilot.world=Navezgane -testpilot.gamename=TestPilotLocal -testpilot.queue=D:\testpilot-queue
```

## How connect/hostload work

- **connect**: calls `InviteManager.HandleIpPortInvite(ip, port, password, onFinished)` — the
  same public API the game uses for "join by IP:port" invites (e.g. from Discord). It builds a
  `GameServerInfo` and calls `ConnectionManager.Connect` for you. No reflection, no bypassing
  anything.
- **hostload**: sets `GamePrefs` (`GameWorld`, `GameName`) and calls
  `ConnectionManager.Instance.StartServers(...)`, mirroring the pattern
  `XUiC_MainMenu.quickContinue()`/TFP's internal `AutomationRunner` use to host a local world.

## Other dialogs that block startup

Two vanilla UI prompts stand between a fresh launch and an actual playable world, and both
have to be dealt with for a truly unattended run:

- **News screen** ("click to continue"). The game itself already has a launch pref for this:
  `-SkipNewsScreen=true` (`LaunchPrefs.SkipNewsScreen`, confirmed by decompiling
  `XUiC_MainMenu.Open`). `SdtdTestPilot` cannot set this on your behalf — `LaunchPrefs` values
  are read-only once the game has finished parsing its command line — so pass it explicitly
  every time you launch for testing.
- **Spawn confirmation** ("Ready to spawn?" / "Random Spawn"). This one *is* handled
  automatically: `WorldReadyWait` calls `AutoSpawnDriver.RequestSpawnIfNeeded()` on every poll
  tick while waiting for the primary player to exist. It does exactly what the "Spawn"/"Random
  Spawn" button does internally — `GameManager.canSpawnPlayer = true` on a host/server,
  `GameManager.RequestToSpawn()` on a remote client (confirmed by decompiling
  `XUiC_SpawnSelectionWindow.SpawnButtonPressed`) — but only once the client is actually ready.
  Requesting a spawn too early crashes `EntityPlayerLocal.Init` on the incoming
  `NetPackagePlayerId` (observed: `NullReferenceException` in `SetFirstPersonView`, from
  `characterMatrixOverride` not being wired up yet) and gets the client disconnected. A UI-ready
  check alone was not enough against a remote dedicated server in testing, so
  `AutoSpawnDriver.IsReadyForSpawnRequest()` mirrors the same readiness gate
  `XUiC_SpawnSelectionWindow.updateLoadState()` itself waits on before letting a human press the
  button: `GameManager.gameStateManager.IsGameStarted()`, enough chunks displayed
  (`World.m_ChunkManager.GetDisplayedChunkGameObjectsCount()` vs `GameUtils.GetViewDistance()`,
  skipped when `World.ChunkCache.IsFixedSize`), `DistantTerrain.IsTerrainReady`, and
  `LocalPlayerUI.GetUIForPrimaryPlayer().xui.IsReady`.
- **Discord login prompt**: not handled by this mod. If your test machine's Discord account is
  linked in a way that triggers this prompt, disable the Discord integration in the game's
  Options once on that machine; it does not reappear afterward.

Both modes wait for `GameManager.Instance.World.GetPrimaryPlayer() != null` (up to
`-testpilot.readytimeout` seconds) before opening the command queue, so a driver never races a
command against a still-loading world. **Bump `-testpilot.readytimeout` well above the default
120s for `connect` mode against a server the client hasn't talked to before** — the client has
to download the world data first, and that alone took over two minutes in testing; 300s was
enough. `hostload` mode has no such download and reached ready in well under a minute at the
default.

The trigger point is `ModEvents.MainMenuOpened` (the game's own extension point, invoked from
`XUiC_MainMenu.OnOpen`) — no Harmony patch needed.

## Command queue protocol

All I/O is local files under `-testpilot.queue=<dir>`. This mod never opens a socket of its
own; the only external surface is this directory, so filesystem permissions on it are the
whole security boundary.

```
<queue>/
  READY                 # created once the poller starts watching; sync point for a driver
  in/00000001.cmd       # driver writes here (see "Writing files atomically")
  processed/00000001.cmd  # moved here after being run (audit trail, never deleted automatically)
  out/00000001.result   # this mod writes the result here
```

**Writing files atomically**: both sides write to `<name>.tmp` and then rename to the final
name. A same-volume rename is atomic, so a reader never observes a partially written file. A
driver script must follow the same convention when submitting commands — write the `.cmd`
content to a temp file in the same directory, then rename it to `<id>.cmd`.

Command file (`in/00000001.cmd`): plain text, the console command line to run, e.g.
```
vtttest list
```

Result file (`out/00000001.result`): single-line JSON, e.g.
```json
{"id":"00000001","command":"vtttest list","ok":true,"output":"[vtttest] no destinations","timestamp":"2026-07-26T03:14:00.0000000Z"}
```

`ok` reflects whether `SdtdConsole.Instance.ExecuteSync` threw, not whether the command's own
output indicates success — for `vtttest` specifically, check its own `VTT_TEST_RESULT` JSON
marker inside `output` (see `docs/GameBehaviorTesting.md`).

## Typical usage with vtttest

1. Launch the client with `-testpilot.mode=connect ...` pointed at a Docker dedicated server
   that already has a Debug build of `VisitedTraderTeleport.dll` + `EnableTestHarness.txt`
   installed.
2. Wait for `<queue>/READY`.
3. Submit `vtttest record <traderEntityId>`, `vtttest teleport <destinationKey>`, etc. through
   the command queue; each becomes a `.result` file.
4. Cross-check `VisitedTraderTeleportData.json` on the server side, same as any other
   `vtttest`-driven test.

## Safety

- `SdtdTestPilot` only compiles into a Debug build, and even then only activates with the
  marker file **and** a valid launch argument (three independent gates).
- It never opens a network listener; every external interaction is a local file under a
  directory the driver script controls.
- Its command queue lets an external caller run **any** console command through
  `SdtdConsole.Instance.ExecuteSync`, which is exactly as powerful as a Telnet/RCON/F1 console
  session. Treat the queue directory's access control accordingly, and only ever run this mod
  against disposable test worlds/servers.
