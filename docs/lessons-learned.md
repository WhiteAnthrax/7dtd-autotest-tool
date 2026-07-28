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

**Workaround used here**: point the server at a brand-new `GameName`/`WorldGenSeed` (see
`docs/runbook.md`), which also gives every player a fresh, alive character. Not
automated by this tool yet - a "use a disposable world every run" mode (vs. "reuse one
persistent world") is a plausible future improvement, since both have legitimate uses
(disposable = fully deterministic; persistent = faster, closer to a real long-lived
server).

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
