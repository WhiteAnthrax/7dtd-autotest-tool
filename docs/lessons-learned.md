# Lessons Learned

Non-obvious pitfalls hit while building this tool, kept here so they don't get
rediscovered the hard way a second time.

## PowerShell `-File` mode parses arguments with Win32 (cmd.exe) rules, not its own

`ssh host "powershell.exe ... -Command \"...\""` lets PowerShell's own parser handle
quoting, so single-quoted strings (`'C:\Some Path\x'`) work as expected. But
`run_on_omen_script` (`lib/ssh-omen.sh`) uses `-File script.ps1 <args>`, and the
arguments after `-File` are split by the *calling* process (effectively cmd.exe rules)
*before* PowerShell ever sees them. Single quotes are not special there - a value like
`'C:\Some Path\x'` splits into two arguments at the space, corrupting the path.

**Fix**: any `-File` argument value that can contain a space (paths, multi-word
strings) must be wrapped in escaped double quotes by the caller:
`-ProjectPath "\"$path\""`, not `-ProjectPath "'$path'"`. Verified with a minimal
`param([string]$Foo)` test script before trusting this in the real scripts.

## PowerShell's own parameter binder can't tell a `-`-prefixed value from a new flag

`Build-DebugMod.ps1` originally took `[string[]]$ExtraBuildArgs` so callers could pass
`-p:GameFlavor=v26` straight through to `dotnet build`. Over `-File`, a value starting
with `-` (like `-p:GameFlavor=v26`) gets mistaken by PowerShell's parameter binder for
the start of a new named parameter, and the intended parameter ends up with no value at
all ("parameter 'ExtraBuildArgs' argument not supplied").

**Fix**: don't generic-pass-through values that start with `-` through `-File`. Use a
dedicated parameter (`-GameFlavor v26`) and build the `-p:...` string inside the script
instead.

## `docker compose restart` doesn't make the new log file appear instantly

`docker_server_wait_mod_loaded`/`docker_server_wait_started` work by grepping the
*newest* `output_log__*.txt`. Right after `docker compose restart`, there's a window
where the new container process hasn't written its own log file yet, so "newest log"
is still the *previous* run's - which, if that previous run had already fully started,
already contains "StartGame done" and "Loaded Mod: ...". The wait functions returned
instantly, believing a stale log's success. In practice, a client immediately launched
against this false-positive got rejected: "still initializing the server" - the world
genuinely wasn't ready yet.

**Fix**: `docker_server_restart` now captures the pre-restart log path and blocks on
`docker_server_wait_new_log` until a *different* log file exists, before returning.
Callers of `docker_server_wait_mod_loaded`/`wait_started` after a restart are then
guaranteed to be looking at the right log.

## `next_id()` called inside `$(...)` never updates a counter variable

The first version of `bin/05-run-scenario.sh` used an incrementing `CMD_SEQ` variable
for command-queue IDs, incremented inside `next_id()`. But every call site did
`id="$(next_id)"` - a command substitution, which bash runs in a **subshell**. The
subshell's increment to `CMD_SEQ` is invisible to the parent shell once the subshell
exits, so every single call returned the same id (`00000001`). Every command after the
first silently read back a *stale* `out/00000001.result` from an earlier command
instead of waiting for its own - producing results that looked plausible but were
actually leftovers.

**Fix**: `next_id()` returns `date +%s%N` (nanosecond timestamp) instead of an
incrementing counter - no shared state needed, so subshell scoping can't break it.

## `grep` finding no match + `pipefail` + `set -e` = the whole script dies silently

`TRADER_ID="$(... | grep -oP '...' | head -1)"` looks safe, but under `set -euo
pipefail`, if the `grep` finds nothing it exits 1, `pipefail` propagates that as the
whole pipeline's exit status, and `set -e` kills the script right there - **before**
the caller's own `if [ -z "$TRADER_ID" ]; then ...` handling ever runs. This looked like
the script just stopped with no error message.

**Fix**: append `|| true` to every such pipeline where "no match" is an expected,
handled case (`grep ... | head -1 || true`). Only omit it where a missing match should
actually be fatal.

## `vtttest record`'s reported key can lag the server when run from a network client

`VttTestHarness.RunRecord` (in the VisitedTraderTeleport repo) originally reported
`VisitedTraderStore.GetKey(trader)` (a raw, non-canonicalized key) as `record`'s
result. VisitedTraderTeleport was patched (PRs #40/#42 there) to instead look up the
*canonicalized* destination from `GetDestinations()` right after `Record()` returns and
report that key instead - more useful for a driver that wants to `teleport` to what it
just recorded.

That fix works when `vtttest record` runs on the server (or a local/hosted client). It
does **not** reliably work when `SdtdTestPilot` submits the command to a *networked*
client: `Record()` on a client-only connection just fires a `ReportVisit` network
message and returns immediately - the server hasn't processed it yet, let alone sent
back a snapshot update, so the client-side destination cache `GetDestinations()` reads
from usually doesn't have the new entry yet. The lookup silently falls back to the raw
key, which may not match anything the server actually stored.

**Fix (in this repo, not in VisitedTraderTeleport)**: `bin/05-run-scenario.sh` doesn't
trust `record`'s reported key at all. It records `RECORD_RAW_KEY` for reference, then
resolves the *real* key from a subsequent `vtttest list` call (by matching the raw
key's npc-id prefix) - by the time `list` runs a few seconds later, the round trip has
had time to complete. This only disambiguates correctly because visit history is reset
before every run (see below), so at most one destination per npc id can exist.

## Leftover visit history makes `vtttest record` results non-deterministic

VisitedTraderTeleport's `CanonicalizeDestination` merges a new visit into an *existing*
recorded destination if it falls within an already-recorded trader area. On a
long-lived test world, a "new" `vtttest record` for a trader the player has never
talked to before can silently attach to a *stale* destination left over from a previous
test run - not a bug in this tool, but it makes results depend on what earlier runs
happened to leave behind (observed: recording a trader picked up an unrelated existing
destination 42+ meters away instead).

**Fix**: `03-deploy-mods.sh` backs up and deletes `VisitedTraderTeleportData.json`
before every run (must happen *before* the server restart - `VisitedTraderStore` only
reads this file on world load); `07-teardown.sh` restores it afterward.

## A dangerous teleport destination kills the player - and the death persists

The scenario originally teleported to *whatever other destination already existed* in
the visit history. On a world with old test data, that could be clear across the map in
an unrelated, zombie-infested area. The player died there, and - since world state is
just saved to disk - that death outlived the test run: the *next* run started with a
dead character, `health=0`, unable to act normally.

**Fix**: the scenario now spawns *two* fresh traders right next to the player's current
position (`se <playerId> npcTraderBob 1` / `npcTraderJen 1`) instead of relying on
whatever's already in the visit history, records both, and teleports between them. Both
ends of the "trip" stay in a known-safe spot. This doesn't fix a death that already
happened in a *previous* run, though - see the next entry.

## A pre-existing death carries over into the next run regardless of scenario safety

Even with the safe-teleport fix above, a character that died in an *earlier* run (e.g.
before that fix existed) stays dead in the save - there's no console command found so
far that revives a dead player, and this mod doesn't attempt to synthesize one.

**Fix, now automated**: `run-roundtrip.sh --fresh-save` runs against a throwaway save, so
the character is always fresh and alive. `01-start-server.sh` rewrites `sdtdserver.xml`'s
`GameName` to `<GAME_SAVE_NAME>Fresh<UTC timestamp>` before starting the server and
records the name; `07-teardown.sh` restores the config and deletes the save afterwards.
Without the flag the persistent save is reused, which is faster and closer to a real
long-lived server - both modes have legitimate uses.

Two things worth knowing about how that is built:

- **Only `GameName` is changed, not `WorldGenSeed`.** `GameName` selects the save slot,
  which is what carries player state and visit history - so changing it alone gets the
  full determinism benefit. `WorldGenSeed` selects the *terrain*, and changing it forces a
  full RWG generation costing tens of minutes and several GB per run for nothing extra.
  The earlier manual workaround changed both, which is why it felt so expensive.
- **The save name has to travel between stages.** `03-deploy-mods.sh` and `06-verify.sh`
  locate the data file by save name, so they resolve it through
  `effective_game_save_name` rather than reading `GAME_SAVE_NAME` directly. Miss that and
  verification silently checks the *persistent* save - which, on a machine that has run
  this pipeline before, contains a previous run's data and can pass while the run under
  test wrote nothing at all.

Teardown deletes a directory, so it only ever removes a save whose recorded name still
matches the generated `*Fresh<14 digits>` shape. A truncated or hand-edited state file
therefore cannot turn cleanup into "delete the persistent save".

## Discord login prompt hangs the client with no error and no queue activity

If the Windows account's Discord integration is enabled and linked in a way that
triggers a login prompt on the main menu, the client process stays alive and
`Responding: True` (not frozen), CPU time keeps ticking up slightly, but `Player.log`
stops advancing entirely and `SdtdTestPilot` never logs `Connecting to...`. This looks
identical to a generic hang. Reproduced deliberately, the last lines before the log goes
quiet are `[Discord] Logging in with provisional account` followed by
`Can not login with provisional account, platform ID already linked to a Discord account`.

**Mechanism** (decompiled, then confirmed by reproducing and fixing it live):
`DiscordManager` registers a handler on `ModEvents.MainMenuOpening` - the event that
fires *before* the menu opens - and it ends like this:

```csharp
if (!Settings.DiscordFirstTimeInfoShown && !Settings.DiscordDisabled) {
    LocalPlayerUI.primaryUI.windowManager.Open(XUiC_DiscordInfo.ID, _bModal: true);
    return ModEvents.EModEventResult.StopHandlersAndVanilla;   // first-time info dialog
}
if (Settings.DiscordDisabled) return ModEvents.EModEventResult.Continue;   // the only escape
Init();
XUiC_DiscordLogin.Open(null, _showSettingsButton: true, _waitForResultToShow: true, _skipOnSuccess: true);
AuthManager.AutoLogin();
return ModEvents.EModEventResult.StopHandlersAndVanilla;       // login prompt
```

`StopHandlersAndVanilla` suppresses the *vanilla* main-menu open as well as other
handlers, so `XUiC_MainMenu.OnOpen` never runs, `ModEvents.MainMenuOpened` never fires,
and `MainMenuTrigger` - which subscribes to exactly that event - never gets a chance to
run. That is why the hang produces no error: nothing failed, the menu simply never
opened. Note the first branch: on an account that has never seen the Discord info dialog,
this blocks even without a linked Discord account.

**No launch argument can fix this.** `DiscordDisabled` *is* a real `EnumGamePrefs` entry
and `GameStartupHelper.ParsePref` does generically accept `-<GamePrefName>=<value>` for
it - the same mechanism that makes `-SkipNewsScreen=true` work - so on paper
`-DiscordDisabled=true` should work. Live-tested anyway (forcing `-DiscordDisabled=false`
against a persisted `True`) and it does not: `DiscordManager` reads the pref before
`GameStartupHelper.InitGamePrefs()`/`ApplyParsedGamePrefs()` applies command-line
overrides onto `GamePrefs`. `-SkipNewsScreen=true` works only because the news screen is
read late enough for the override to land in time. A good reminder that a mechanism which
is provably present in the decompiled code can still lose a startup-ordering race.

**Fix, now automated**: the setting is persisted in the Windows registry (the Windows
build routes `GamePrefs` through Unity PlayerPrefs via `SaveDataPrefsUnity`, not through
the `prefs.cfg` file that `SaveDataPrefsFile` would use), under
`HKCU\Software\The Fun Pimps\7 Days To Die`. `04-launch-client.sh` disables Discord
before launching and `07-teardown.sh` puts the previous state back; see
`lib/windows/Set-DiscordDisabledPref.ps1`.

**There are two storage formats, and a machine running both game lines needs both:**

- v3.x: its own GamePref, value `DiscordDisabled_h<hash>` (DWORD).
- v2.6: a field inside a JSON blob in value `DiscordSettings_h<hash>` (REG_BINARY,
  UTF-8 JSON with a trailing NUL).

v3.x treats the JSON blob as legacy - `DiscordSettings.Load()` migrates it once and then
calls `SdPlayerPrefs.DeleteKey("DiscordSettings")`. Because the registry key is shared by
every 7DTD install on the machine (Unity keys it by company/product name, not by install
folder), **every v3 run wipes the setting the v2.6 client reads**, and the next v2.6 run
silently falls back to "Discord enabled" and hangs. That is a genuinely nasty failure
mode: v26 breaks because of something a *v3* run did, with nothing in the v26 logs
pointing at the cause beyond `[Discord] Saving settings with DiscordDisabled=False`.
Writing both formats on every run makes the order of profile runs stop mattering.

Three traps worth remembering when touching this:

- **`Get-ItemProperty` throws `InvalidCastException` on this key.** It holds 300+ values,
  some of a type the PowerShell registry provider cannot cast, and it fails on the *whole
  key* - which reads as "the value isn't there" and sent an earlier investigation off
  looking for a nonexistent config file. Use the .NET API
  (`[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(...)`, `GetValueNames()`,
  `GetValue()`) instead. `reg query` also works for eyeballing it.
- **The registry write goes to the HKCU hive of whoever runs the script**, while the
  client runs as a scheduled task under `OMEN_USER_ID`. If those ever differ, the write
  lands in the wrong hive and silently does nothing. The script hard-fails on that
  mismatch rather than letting it become another mystery hang.
- **`[byte[]]` matters when writing the JSON blob.** In PowerShell,
  `[Text.Encoding]::UTF8.GetBytes($s) + [byte]0` yields an `Object[]`, and
  `RegistryKey.SetValue(..., Binary)` rejects it with a type-mismatch `ArgumentException`.
  Build the array explicitly.

Because the setting is per company/product rather than per install, there is nothing
per-profile to configure - which is convenient, and is also exactly why the v3/v2.6
interaction above exists.

## "Newest file" is the wrong way to find a save's data file on a shared machine

`03-deploy-mods.sh`/`06-verify.sh` originally found the relevant
`VisitedTraderTeleportData.json` by "most recently modified file under
`SERVER_SAVES_DIR`". This machine's Saves directory accumulates data from *every* world
ever tested on it. A brand-new world's own data file doesn't exist until the first
`vtttest record` against it - so on that first run, "newest file" silently fell back to
some *unrelated* world's file, which then got backed up, deleted, and (so far, luckily)
correctly restored. Had teardown failed partway, that would have been data loss for a
world this tool had no business touching.

**Fix**: match on `GAME_SAVE_NAME` (must equal `sdtdserver.xml`'s `GameName`) via
`find "$SERVER_SAVES_DIR" -path "*/${GAME_SAVE_NAME}/VisitedTraderTeleportData.json"`.
The world-name path segment is left as a wildcard (RWG world names are seed-derived,
not predictable ahead of time); the save name is the one value this tool actually
controls and knows for certain.

## A `set -e` script that dies outside `die` tells you nothing at all

`01-start-server.sh` once exited 121 seconds into a 480-second wait, printing not one
line. No timeout message, no error - output simply stopped, and the run reported
`start-server failed` with nothing to go on. Re-running the same stage immediately
afterwards succeeded in 127 seconds, so there was nothing left to reproduce against.

That is the real defect: under `set -e`, any command that fails somewhere other than an
explicit `die` ends the script silently, which is indistinguishable from a clean early
return. Two changes make it diagnosable:

- `trace_errors` (in `lib/common.sh`) installs an `ERR` trap that logs the file, line,
  exit status and failing command. It needs `set -E` as well, or the trap won't fire for
  failures inside library functions - which is exactly where this one was. Every
  `set -e` stage calls it now.
- `docker_server_latest_log` no longer uses `ls -t ... | head -1`. Callers assign it with
  `x="$(...)"`, so under `pipefail` a benign hiccup in that pipeline (ls racing a file
  that is rotated away, or SIGPIPE once `head` has taken its line) becomes a silent
  `set -e` death. The pure-bash loop that replaced it cannot fail that way.

Honest status: the original silent exit was never reproduced, so this is the most
plausible cause plus a guarantee that a recurrence will actually say something. If it
happens again, the log will now name the line.

## A failure summary that reports the *previous* run's verdict

`run-roundtrip.sh` builds its `ROUNDTRIP_RESULT` line by reading
`output/<profile>/verify-result.json`, which `06-verify.sh` writes. On a run that failed
before `06-verify.sh`, that file is whatever the last run left behind - so a genuinely
broken run printed `"status": "start-server failed"` next to `"verify": {"ok": true}`.

Easy to skim past, and exactly the sort of thing that gets a broken run waved through.
The run now deletes that file before starting, so the verify block only ever describes a
verification that actually ran this time.

## The server updates itself, so client/server version drift is the default

The Docker server runs `startserver-with-update.sh`: it pulls whatever 7DTD release is
current *every time it starts*. The Windows client is a pinned copy that only moves when
someone updates it deliberately. So the two drift apart on their own, without anybody
touching this tool - observed mid-session, when the server went 3.0.1 -> 3.1.0 between one
run and the next.

A mismatched client shows a version dialog and never joins. From the pipeline's side that
is a READY timeout with no error in any log it collects - the only tell was a human
happening to look at the screen. It reads exactly like the Discord hang, and like every
other hang, which is what makes it expensive.

**Fix**: `04-launch-client.sh` compares compatibility versions right after launching.
Two things made this less obvious than it sounds:

- **There is no version file to read before launching.** The exe's `ProductVersion` is
  Unity's (`2022.3.62f2`), not the game's, and the install carries nothing else usable.
  The dependable source is the client's own log line, written ~0.07s into startup:
  `INF Version: V 3.1.0 (b13) Compatibility Version: V 3.1.0, Build: WindowsPlayer 64 Bit`.
  So the check has to happen *after* launch - which is still early enough to be useful,
  since it fires in seconds instead of after the full READY timeout.
- **Player.log is shared by every install on the machine** (Unity keys it by
  company/product, the same reason the Discord setting is shared). A stale line from a
  previous launch - possibly of the *other* profile's client - is easy to read by mistake,
  so `Get-ClientVersion.ps1` only trusts a log that was written to recently, judged
  against the Windows machine's own clock rather than a timestamp passed in from Linux
  (which would break on any clock skew).

Compare **"Compatibility Version"**, not the build number: the client and dedicated-server
packages of the same release carry different build numbers (`3.1.0 (b13)` on both here,
but that is not guaranteed), while the compatibility version is the field the game itself
matches on. Only a confirmed mismatch is fatal - an unreadable version warns and
continues, so the check cannot block a run that would otherwise work.

## Deploying only the DLL means config changes are never actually tested

`03-deploy-mods.sh` used to copy `VisitedTraderTeleport.dll` and nothing else, on top of
whatever mod folder the client and server already had installed. That folder carries the
mod's `Config/` - `Localization.csv`, `dialogs.xml`, `VisitedTraderTeleport.xml` - so a run
testing a localization or dialog change loaded the *previously installed* copy of those
files and passed without the change ever being in play.

Worse than a plain false negative: the run is green, the change looks verified, and the
only symptom is that nothing you changed shows up. The deploy now ships `Config/` from the
build tree alongside the DLL (collected into `output/<profile>/mod-config/` by
`02-build-mods.sh`, so what is deployed is exactly what was built), and teardown restores
the client's original copy.

The general rule: whatever the mod loads at runtime has to be deployed, not just the part
that happens to be the build output.

## A dialog that is logically correct can still reach the screen truncated

`XUiC_DialogResponseList` has a fixed number of `XUiC_DialogResponseEntry` children, built
from the dialog skin's XML. `Update` walks the responses `GetResponses` returned and
assigns them to those slots - and everything past the last slot is dropped, with no log
line and no error. A mod that inserts its own entries (a status header, five destinations,
a paging row) can therefore produce a perfectly correct list that a player sees cut off.

No data-level check catches this, because the data is right. `vtttest dialog dump` reports
both counts - what `GetResponses` produced and how many slots actually hold a response -
and `06-verify.sh` fails when they disagree. The screenshots are the backstop for the rest
of the rendering (clipping, wrapping, panel overflow), which no assertion can see.

## Seeding the client's destination list races the snapshot the dialog itself requests

`vtttest dialog seed` writes synthetic destinations into the client's snapshot cache so
paging can be tested without visiting six traders. But `DialogGetFirstStatementPatch`
calls `RequestSnapshot()` every time the dialog opens, and the server's reply calls
`ApplySnapshot`, replacing whatever was seeded.

Seeding before opening the dialog therefore loses to the server's own (much shorter) list,
non-deterministically - a race that would look like "paging is broken" rather than "the
test seeded at the wrong time". Seed *after* `dialog open`, once that request has already
been answered.

## The queue result came back mojibake, and jq died 1000 bytes in

The first dialog-scenario run failed with `jq: exit 5` and a half-printed dump full of
`こんにちは、何かご用ですか?E` style garbage. Nothing was wrong with the mod, the dialog,
or the JSON: `SdtdTestPilot` writes its result files as UTF-8 without a BOM
(`AtomicFileWriter`), and `CommandResultJson` escapes them correctly.

The damage happened on the way back. `Invoke-TestPilotCmd.ps1` read the file with
`Get-Content -Raw`, and PowerShell 5.1 reads a BOM-less file using the **ANSI code page** -
CP932 on this Japanese-locale Windows host. Whatever survived that was then re-encoded a
second time through `[Console]::OutputEncoding` on its way to stdout and over SSH. The
result was a byte stream that is no longer valid UTF-8, so `jq` parsed until it hit the
first bad byte and exited - which looks exactly like a truncated response, and sent the
first diagnosis chasing a nonexistent output-length limit in `SdtdConsole.Output`.

Two things worth keeping:

- **An ASCII-only test suite hides this indefinitely.** Every earlier scenario dealt in
  destination keys like `traderbob:902:968`. The encoding bug had always been there; it
  only surfaced the first time a test read text a human would actually see.
- **Fix the transport, not the encoding settings.** `Invoke-TestPilotCmd.ps1` now returns
  `B64 <base64 of the file's bytes>` and `testpilot_submit` decodes it, which is immune to
  the locale and console encoding of both machines. Setting `-Encoding UTF8` on the read
  would have fixed only the first of the two re-encodings.
