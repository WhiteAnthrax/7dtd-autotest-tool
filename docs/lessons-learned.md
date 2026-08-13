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

`Build-Mod.ps1` (then `Build-DebugMod.ps1`) originally took `[string[]]$ExtraBuildArgs` so callers could pass
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

## Backup-taking steps quietly become destructive the second time they run

Adding a driver that launches the client once per language (`run-language-sweep.sh`) meant
re-running steps that had only ever run once per run. Three of them take a backup on the
way in, and all three took it unconditionally:

- `04-launch-client.sh` -> `Set-DiscordDisabledPref.ps1 -Mode Apply` recorded the current
  Discord state before disabling it. On a second launch the "current state" is already
  *disabled*, so teardown would faithfully restore that and leave the user's Discord
  integration off for good.
- `03-deploy-mods.sh` re-copies the installed mod to `output/<profile>/server-mod-backup`
  and the live `VisitedTraderTeleportData.json` to `server-data-backup.json`. Run twice,
  the "original" it saves is the Debug build it deployed on the first pass and the visit
  history it just reset.

The Discord one is now first-write-wins (Apply keeps an existing backup). The other two
are not, on purpose: the backup has to be re-taken at the start of each *run*, and there
is no marker distinguishing "second pass of this run" from "first pass of the next run".
So the sweep runs `03` exactly once instead, and its header says why.

The general shape: **a step that is idempotent in its effect is not necessarily idempotent
in its bookkeeping.** Re-deploying the same DLL twice is harmless; re-recording what was
there before it is not. Before putting an existing step in a loop, check every backup,
snapshot and "original" it writes.

## Re-running the roundtrip scenario inside one run can get the player killed

`05-run-scenario.sh` spawns two traders at the player's position, records both, then
teleports to one of them. It resolves which destination to teleport to by matching the
trader's npc id, and that is only unambiguous because `03-deploy-mods.sh` reset the visit
history first - at most one destination can exist per npc id.

Run it a second time without that reset and the assumption is gone. The player has moved
(the first pass teleported them), so the newly spawned traders record *new* destinations
under the same npc ids, and the "second, distinct destination" the script picks to travel
to may now be the one from the previous pass, far away. Teleporting somewhere unprepared
is exactly how an earlier version of this scenario killed the player, and a death persists
into every later run.

That is why the language sweep runs `05` once and repeats only `05b` (which opens a dialog
and seeds destinations client-side, and never teleports).

## Every assertion passed; the screenshot showed the respawn screen

A language sweep reported Polish green - 5 destinations on page 1, 2 on page 2, paging
symmetric, no unresolved keys - and the screenshot was the death/respawn screen, with the
dialog nowhere on it.

The player had been killed while the sweep left them standing idle in the open world for
twenty-odd minutes. Nothing in the dialog data reflects that: `vtttest dialog` drives the
window group directly and reports what the dialog produced, which stays perfectly correct
whether or not the game is actually drawing it. The captured screen is a different thing
from the dialog's state, and only one of them was being checked.

The same death also broke a *different* language in a way that looked unrelated:
`paging_returns_same_page: false`, with page 1 having shifted by exactly one entry. The
destination list is ordered by distance from the player, so the respawn moved the player
and re-paged the list underneath the walkthrough.

Two things came out of it:

- **Assert the observer, not just the output.** `05b-run-dialog-scenario.sh` now reads the
  player's state from vanilla `le` before and after the walkthrough, and `06-verify.sh`
  fails the run if the player died or moved more than 2 m. Position is the stronger of the
  two checks: it catches death, but also teleports and falls, and it is exactly the
  variable the assertions silently depend on.
- **A long unattended run is a hostile environment, and mitigation is not verification.**
  The sweep now runs `killall` and `settime day` before each pass, which removes the usual
  cause. That reduces how often it happens; it is the assertion above that stops it from
  being believed when it does.

## The pipeline verifies a Debug build; users get a Release build

Everything here - the roundtrip, the dialog walkthrough, the language sweep - runs against
a **Debug** build, because `vtttest` and `vtttest dialog` only exist when
`VTT_TEST_HARNESS` is defined, which `VisitedTraderTeleport.csproj` does only for
`Configuration=Debug`. What ships is a Release build, which by design has no harness at
all. So the artifact users download is the one thing that never gets driven.

This surfaced the worst possible way: at release time, after publishing, as "wait, did we
verify the thing we actually shipped?" The answer was no, and finding out cost a
post-hoc scramble instead of a scripted check.

What transfers from a Debug run and what does not is worth being precise about:

- **The `Config/` files do transfer, if you check they are the same bytes.** The
  translations live entirely in `Config/Localization.csv`; the DLL only looks keys up. The
  packaged Config can be compared byte-for-byte against `output/<profile>/mod-config/`,
  which is what the sweep actually deployed. That is a real check, not a hand-wave - do it
  rather than assume the commits match, and compare against the *deployed* copy rather
  than `git show`, whose LF form differs from the CRLF working-tree form.
- **The production code is the same source.** `VTT_TEST_HARNESS` wraps only the three files
  under `src/VisitedTraderTeleport/Testing/`, and no production file has any conditional
  compilation - worth re-checking with a grep rather than believing this note.
- **The Release binary itself transfers nothing.** It was never loaded. Deploy the packaged
  zip to a server, start it, and confirm the mod loads and no exception is thrown. That is
  cheap and it is the only evidence that the shipped DLL runs at all. `PatchAll` is not
  wrapped in try/catch, so a Harmony patch that no longer applies shows up as an exception
  at mod load rather than as silently missing behavior.
- **What still cannot be checked mechanically is the Release build's UI.** Driving the
  dialog needs the harness, and the harness is not in the shipped build. Closing that
  properly means putting a *generic* dialog-open/select capability in `SdtdTestPilot` -
  which is a separate mod, so it can drive a Release build of the mod under test.

## `rm -rf <dir>` you don't own the parent of, then `cp -a src dst`, nests instead of replaces

Replacing a deployed mod folder on the v2.6 server with `rm -rf "$S"; cp -a "$D" "$S"` left
`Mods/VisitedTraderTeleport/VisitedTraderTeleport/` - a broken install - and the server was
started on it before anyone noticed.

`Mods/` there is owned by the container's uid, not the invoking user. `rm -rf` could delete
the directory's *contents* but not the directory itself, so it emptied the folder, failed,
and left it in place. `cp -a src dst` then copied *into* the surviving directory instead of
becoming it.

Replace contents, never the directory: `rm -rf "$S"/*` followed by `cp -a "$B"/. "$S"/`.
That is already what `03-deploy-mods.sh` does for the server-side `Config/`, and it works
whether or not the parent is writable. And verify afterwards - `diff -r` against the backup
takes a second and is the difference between a restored server and a quietly broken one.

## Two red assertions, both the harness being wrong

The first run of the release-package walkthrough failed on two counts, and neither was the
mod:

- **`destinations: 4` where 5 traders had been recorded.** The mod filters out the trader
  you are currently talking to (`DialogPatches`' `IsSameTrader`) - travelling to where you
  already stand is not a destination. The expectation was wrong, not the list.
- **`rendered` shorter than `entries`.** `DialogStatement.GetResponses()` returns every
  response *defined* on the statement, including ones the game then hides because their
  conditions do not hold. A vanilla trader start statement carries 13 and renders 3. The
  count comparison that works fine on the mod's own fully-generated statement reports that
  as silent truncation.

Both were found by printing the dump instead of trusting the verdict. The fix for the second
one is worth keeping: the property actually wanted is not "nothing was dropped" but "nothing
*the mod produced* was dropped", i.e. every `vtt_` entry appears in `rendered`. That is
precise, and it stays correct on a statement full of unrelated conditional responses.

The general rule this is the second instance of: when a check goes red against something
that has been verified another way, suspect the check first.

## A localization release was not a localization-only release

Before publishing 0.7.10, `git diff --stat v0.7.9..v0.7.10 -- src mod` was the cheapest
useful thing anyone did all day. The translation work was the visible change, but the tag
also carried four unreleased refactors that had moved the visit store, trader key
canonicalization, travel cost and travel readiness into `VisitedTraderTeleport.Core` -
`VisitedTraderStore.cs` alone lost 404 lines.

The v2.6 release next to it was genuinely localization-only: its diff was the localization
file, `ModInfo.xml`, and test files behind `#if VTT_TEST_HARNESS`. Same day, same kind of
work, completely different risk.

So: **diff the tag against the previous tag before calling a release safe**, and scope the
verification to what actually changed rather than to what you were working on. Screenshots
of translated text say nothing about a refactor of the code behind them; that is what
`05t-run-release-travel-scenario.sh` exists for.

## A blocklist of "things that are not X" will keep missing things that are not X

`VisitedTraderTeleport` decided whether to drag an entity along on a teleport by asking
"does the player own it, and is it not one of the types we know are not companions?" That
missed drivable vehicles, got a type added for them, and then missed placed turrets - which
were being uprooted from bases and dropped at traders on every single teleport.

The type list was never the problem. `belongsPlayerId` means "this player owns it", which is
equally true of a turret, a vehicle and a drone; it says nothing about following anyone.
Reading ownership as companionship guaranteed a stream of exceptions, one per owned entity
type the game ever adds.

The fix was to ask the positive question instead - and it turned out the codebase already
had the answer half-written. Decompiling SCore showed its own `IsHired` is
`GetLeaderOrOwner(id) != null`, reading two Buffs custom vars that this code was already
checking as a *fallback* under the ownership test. Deleting the broader condition was the
whole fix.

Two things worth carrying:

- **When a blocklist misses something twice, stop extending it.** The second miss is the
  signal that the predicate is asking the wrong question, not that the list is short.
- **Look for the authority's own predicate before inventing one.** The issue proposed using
  `EntityUtilities.GetCurrentOrder` for positive identification; reading it showed it
  returns `Orders.Wander` by default for *any* `EntityAlive`, so every entity "has" an
  order and the test would never have excluded anything. The neighbouring `IsHired` was the
  right one, and it was three lines long.

## Some verification is not reachable from a script, and saying so beats implying otherwise

The turret fix could not be reproduced end to end. A console-spawned turret comes out with
`belongsPlayerId = -1` - ownership is assigned when a *player* places one - so the very
condition that triggered the bug cannot be set up headlessly. Nor can a real SCore-hired
companion: hiring is dialog-driven and SCore's only cvar console command targets the primary
player.

What was reachable: the decision table as unit tests, a live `EntityTurret` classified by
the shipped predicate on real hardware, and a green roundtrip (which runs the companion
gather after every teleport). What was not: an *owned* turret, and the "real companions are
still gathered" direction, which rests on the diff instead - the Leader/Owner branch is
untouched and only a broader condition was removed.

`vtttest companions` came out of this: it prints every live entity's type, `belongsPlayerId`,
Leader/Owner vars, the verdict, and what the old ownership rule would have said. Both
previous misses were invisible from outside - they surfaced as "my turret moved". The next
disagreement is now a five-second question instead of a bug report.

## Client-side and server-side are different worlds, and the console does not say which one you are in

Building a scenario that had to set up server-side state took three wrong turns, each of
which produced a confident, plausible, wrong answer:

1. **Marked an entity through the client command queue.** `GatherCompanions` runs on the
   server, so the marker landed on a copy the server never saw. The scenario then reported
   that companions were not being gathered - a product bug, apparently, complete with a
   probe agreeing with itself because the probe was reading the same client-side copy.
2. **Spawned entities through the client command queue.** Worse: a client-spawned entity
   only exists on the client. Its id means a different entity on the server, or none
   (`no living entity with that id`). Entities spawned from the *server* console replicate
   to the client with the same id, so the server is the only side worth spawning from.
3. **Built without committing.** `02-build-mods.sh` runs `git archive <branch>`, so
   uncommitted work is silently not built. The symptom was the server answering with an
   older version of a command's usage string - which reads like a deployment problem rather
   than a "you never committed it" problem.

The reason all three were slow to spot is that `lib/testpilot-queue.sh` and a server console
look identical from a script: both take a console command and return text. Nothing in the
call says which process will run it. That is why `lib/server-console.sh` exists as a separate
thing with its own name rather than a flag on the existing helper.

The generalisation: **in a client/server game, "where does this run?" is part of every test
step, not a detail.** When a check disagrees with something already established, ask which
process answered before concluding anything about the product.

## A stand-in that moves on its own cannot measure whether something moved it

The companion scenario first used a rabbit as the stand-in hired companion. It was gathered
exactly as designed - to within 1.8m of the player, per `CompanionSpotFinder` - and had
hopped 20m away again by the time the positions were read twenty seconds later. The check
read that as "the companion was not gathered".

The stand-in is a trader now: an `EntityAlive` that satisfies the same predicate and stays
where it is put, so any movement is attributable. Where a passive stand-in is not available,
prefer evidence the system emits itself - here `GatherCompanions` logs
`Gathered N companion(s)`, which a wandering animal cannot produce.

## One topology is not the topology

The companion scenario was green against a dedicated server and that felt like enough. It
was not: travel branches on `player is EntityPlayerLocal`, and each branch has its own
`GatherCompanions` call site with a different centre. A dedicated-server run never executes
the single-player one.

Making it run both ways cost about an hour and immediately produced two more instances of
the same family of mistake - each quiet, each plausible:

- **The READY wait was skipped.** Returning early to skip a server-only version check took
  the wait with it, so the scenario ran against a client that had not finished loading a
  world and reported that it could not find the player.
- **The wrong log was read.** A hosting client writes Unity's `Player.log` under
  `AppData\LocalLow\The Fun Pimps\7 Days To Die`, not the dedicated server's
  `output_log__*.txt`. The run counted zero gathers while the companion had visibly been
  moved to exactly the 1.8m the spot finder places it at.

Both are the same shape as the earlier client/server mix-ups: a thing that exists in two
places, and code that names one of them. The fix each time was an abstraction that asks
"which side is this?" once - `lib/world-console.sh` - rather than remembering at every call.

## Four ways the same scenario broke on a second topology

Making the companion check run in hostload as well as against a dedicated server took four
more rounds, and none of them announced itself as an error. They are listed because the
shape repeats: something exists in two places, and the code names one of them.

- **The READY wait was skipped.** Returning early to skip a server-only version check took
  the wait with it, so the scenario ran against a client still on its loading screen. The
  failure screenshot showed a loading tip - which is exactly why the scenario captures one.
- **The wrong log was read.** A hosting client writes Unity's `Player.log` under
  `AppData\LocalLow\The Fun Pimps\7 Days To Die`, not `output_log__*.txt`. The run counted
  zero gathers while the companion had visibly moved to the 1.8m the spot finder uses.
- **The player's entity id was 0.** In a freshly hosted world the local player really is
  entity 0 (confirmed in `le`), and `se 0 <class> 1` does nothing at all - silently. Spawning
  at explicit coordinates instead needs no id and behaves the same in both topologies.
- **The hosted save persisted between runs.** `03-deploy-mods.sh` resets the *server's* visit
  history, and hostload skips that stage, so destinations accumulated. The scenario then
  travelled to a trader recorded by an earlier run, hundreds of metres away, and the trip
  aborted as "destination was not ready". The hosted save is now cleared before each run,
  which also stops a player killed by one run from poisoning the next.

Worth keeping: the assumption that a green run in one topology says much about the other is
not a small one. Every single step of this scenario needed adjusting, and each adjustment was
found by reading what the game actually reported rather than by reasoning about what should
happen.

## A fallback that appends: `cmd || printf '[]'` when cmd already printed

The companion scenario got all the way through - markers written, both traders recorded,
travel completed, `Gathered 1 companion(s)` in the server log - and then died assembling its
result file:

```
jq: invalid JSON text passed to --argjson
```

The bad value was the diagnostic probe, captured as
`PROBE_SERVER="$(probe_world "$PLAYER_ID" 2>/dev/null || printf '[]')"`. Against a *Release*
package the probe command does not exist, so the `grep` for its output lines matched nothing
and, under `pipefail`, failed the whole pipeline - even though the trailing `jq -s .` had
already turned "no lines" into a perfectly good `[]`. The fallback then ran *in addition to*
output that was already complete, and the variable ended up holding `[]\n[]`.

Three things worth carrying forward:

- **`||` is not "instead of", it is "as well as".** A fallback only substitutes when the
  command printed nothing. If the command can print *and* fail, the two outputs concatenate.
  Let the pipeline succeed (`{ ... || true; } | jq -s .`) and keep the fallback for the case
  where nothing was produced at all.
- **`pipefail` turns "grep found nothing" into "the command failed".** An empty match is a
  normal result for a probe, not an error.
- **`--argjson` will not tell you which argument was bad**, and this call had sixteen of
  them. The values now go through a `json_arg <name> <value>` helper that validates each one
  and names it in the failure, which turned a guessing game into one line of output.

The tell was in the log the whole time: `world probe: []` was followed by a bare `[]` on the
next line. A value printed across two lines where one was expected is worth a second look.

## Do not build a harness command into the mod under test

The same scenario also had to stop using `vtttest record` and `vtttest teleport`. Those are
console commands compiled into VisitedTraderTeleport itself, behind a Debug-only guard - so
the moment the check was pointed at the ZIP users actually download, they were not there:

```
*** ERROR: unknown command 'vtttest'
```

Recording a visit and travelling now go through `testpilot dialog open|select`, which lives
in the separate SdtdTestPilot driver mod and only calls public game APIs. That means the
scenario drives the shipped build the way a player does - opening the trader's dialog is what
records the visit - instead of calling a shortcut that exists only in a build nobody ships.

The general rule: a test hook compiled into the artifact under test can only ever verify a
build that is not the one you ship. Put the hooks in a separate driver mod, and check the
real package.

## The harness needs to own the server's files, and one instance did not

`--fresh-save` died on the v2.6 profile before anything started:

```
ERROR: 01-start-server.sh:53 failed (exit 4): sed -i -E "s|(<property name=\"GameName\"...
```

`sed -i` exit 4 is "could not write the file". That server's `data/` tree was owned by uid
166535 - the id the container's own user ended up with when the instance was first created -
while the v3.0 instance's tree was owned by the account running the harness. Both compose
files pass `UID/GID=1000`, so this was a difference in how the two instances were set up, not
in how they run.

Three of the harness's stages need to write there: `01-start-server.sh` rewrites `GameName`
in `sdtdserver.xml`, `03-deploy-mods.sh` creates `Mods/SdtdTestPilot/`, and `07-teardown.sh`
removes it again. None of them can, without write access to that tree.

The fix was to make the instance look like the other one:

```
sudo chown -R 1000:1000 /path/to/<instance>/data
```

Worth noting rather than papering over with `sudo` inside the scripts: files the harness
creates as root stay root-owned, and the next run - or the game server itself - then trips
over them. Ownership is a property of the environment, so it belongs in the environment.

The symptom is also worth recognising. It only appeared once `--fresh-save` was used against
that instance; every earlier run there had written *inside* an existing mod directory that
happened to be owned correctly, so the tree looked writable when it was not.

## `git archive <branch>` packages the working copy's idea of that branch

Both release lines had their PRs merged within three seconds of each other, and both packages
were built a minute later. `main` had been pulled first; `v26-work` had not. `git archive`
does not care - it archived the local branch, so the v2.6 ZIP was built from the commit
*before* the one the release notes point at.

Nothing caught it, and nothing would have:

- The ZIP is named after the mod version, which had not changed.
- The verification recorded the file name, then (after an earlier lesson) the sha256 - both of
  which tie the ZIP to its *test run*, not to its *source*.
- The two commits differed only in Debug-only code, so the shipped build was in fact
  equivalent. That is luck, not a control: the next such slip could be a real fix.

The step was manual, which is the actual defect. `bin/build-release-package.sh` now builds
from a named ref, refuses when the local ref is behind its remote, and writes a
`.provenance.json` recording the commit; `run-release-verification.sh` copies that into its
result after checking it describes the file in front of it.

General shape, worth recognising elsewhere: when a build reads state from the working copy
(current branch, uncommitted files, a local checkout that may lag), the artifact's identity
depends on something nobody wrote down. Either pin it explicitly or record what it was.

## Two runs, one output directory, and a package declared broken

A release verification reported the 3.0 package failing every language:

```
server log since travel: Teleported=1 failed=0 exceptions=0
ERROR: no VisitedTraderTeleportData.json found under .../Saves for save name 'AutotestSafe'
```

Those two lines contradict each other - the trip happened, the game logged it - which is the
tell. The travel scenario looks the visit records up in the save slot *this run* used, read
from `output/<profile>/fresh-save-name.txt`. The file was gone, so it fell back to the
profile's persistent save, where nothing from this run had ever been written.

It was gone because the previous run's teardown was still finishing when the next run was
started. Teardown removes the throwaway save and that state file as its last act; the new run
had already written its own copy fifteen seconds earlier, and the old teardown deleted it.
Same output directory, two runs, no lock.

`hold_profile_lock` now takes an `flock` on `output/<profile>/.run.lock` for the life of the
process, and every driver takes it before doing anything. A second run against the same
profile stops with "another run is already using output/<profile> (its teardown may still be
finishing)" instead of quietly reading the other run's state.

Two things worth keeping:

- **A green step followed by a red one that contradicts it means the check is wrong.** This is
  the fourth time in this pipeline. Every time, the check was the problem.
- **Teardown is part of the run.** "The result line printed" is not "the run finished" - the
  driver still has a server to restart, a client to stop and files to clean up.

## Do not edit a shell script while a run of it is in flight

A v2.6 run died with:

```
./bin/run-scenario-check.sh: line 173: unexpected EOF while looking for matching `"'
```

The script was fine - shellcheck had just passed on it. It died because the file was edited
*while that run was executing*: bash reads a script incrementally, remembering a byte offset,
so rewriting the file underneath a running instance makes it resume in the middle of whatever
is now at that offset. Adding one scenario to a `case` shifted everything below it.

Cheap habit: when a run is in the background, either wait for it or edit a copy. The failure
looks like a syntax error in code that has none, which is a bad way to spend ten minutes.

## Two traders standing near each other are one destination

Testing paging needs more than five recorded destinations, and recording is just opening a
trader's dialog - so the obvious move is to spawn seven traders and open each one. It
produced an empty list.

The mod builds a destination key as `{npcID}:{areaX}:{areaZ}`
(`VisitedTraderStore.GetKey`), where `areaX`/`areaZ` come from the trader's *trader area*
when it has one and from its rounded position otherwise. Spawned traders standing a few
metres apart end up in the same area, so seven copies of one prefab collapsed into a single
destination - which was then filtered out of its own list, leaving nothing to page through.

The save made it unambiguous:

```json
"traitorjoel:478:1093": { "PositionX": 472.0, "AreaX": 478, "AreaZ": 1093 }
```

One key, and a stored position that belongs to a different trader than the one that created
it. Position and identity are not the same thing here.

So the scenario records two groups: four *different* traders where the player stands, then
the player is moved 400m and three more are recorded there. Different `npcID` distinguishes
traders in one place; being somewhere else distinguishes the same `npcID`. Seven distinct
destinations, six after the one being talked to is filtered, which is exactly two pages.

Two things this cost, both worth avoiding next time:

- **The first diagnosis was wrong** ("the spawn coordinates are being ignored"), and the run
  that disproved it was the one that logged where each trader actually stood: 454, 460, 466,
  478... all distinct. Log the observed value, not the requested one.
- **The scenario failed three steps downstream of the real problem** ("no next-page entry"),
  which reads as a pager bug. It now fails at the point the count is wrong, and says how many
  destinations it actually got.

## Where state lives decides which process you ask - and the answer is not always "the world"

Three scenarios have now been written by asking "where does this live?", and the travel-cost
one got two different answers in the same script:

- **Entity state** (a companion's owner marker, a spawn, a teleport) lives with the world, so
  it goes through `world_console` - the server when there is one.
- **A player's inventory** does not. Giving items to the *server's* copy of a remote player
  answered `could not fit 21 x casinoCoin in the backpack`; the real inventory belongs to the
  client. That is also where the mod charges from - `Consumed local travel cost for ...` -
  so the client is both the right place to put the items and the right place to count them.
- **Log lines follow the code, not the world.** Counting `Consumed` in the *server's* log
  found nothing and reported "the consumption never ran", while the inventory had visibly
  gone from 21 to 14. `client_log_grep_count` reads the client's `Player.log` in either
  topology, which is also the only way the over/under-removal warnings would ever be seen on
  a dedicated server.

The general form: "which process owns this?" has to be asked per *piece of state*, not once
per scenario. Getting it wrong produces a plausible wrong answer rather than an error - which
is the same shape as every other client/server mix-up in this file.

## `git archive` builds the committed tree - including for the driver mod

`02-build-mods.sh` archives both mods with `git archive`, so a freshly written source file
that has not been committed is simply not in the build. That cost a debugging session once on
the mod under test, and then again on SdtdTestPilot: a new `testpilot inventory` command was
answered by the console with the *old* build's usage line, which reads like a typo in the
command rather than a missing file.

The build now refuses to run when the source it is about to archive has uncommitted changes,
listing them, with `ALLOW_DIRTY_BUILD=1` to override on purpose.

## A config the game refuses is a config the test never applied

The travel-cost scenario reported that the mod charged nothing and showed no confirmation -
in hostload, on both lines, while connect passed. That reads like a single-player bug.

It was the harness. The client's config was rewritten with an inline PowerShell `-Command`,
and the attribute quotes did not survive `ssh -> powershell -Command`:

```xml
<TravelCost enabled=true item=casinoCoin perMeter=0.1 minimum=7 />
```

The mod said so, in the client's own log, the whole time:

```
[VisitedTraderTeleport] Could not read config, using Personal: 'true' is an unexpected token.
```

It fell back to its defaults - cost disabled - and the scenario dutifully reported that
nothing was charged. Connect passed because there the *server's* copy governs, and that one
was written with `sed`, correctly.

Three things worth keeping:

- **A parse failure is a silent fallback.** Software that "uses defaults on a bad config"
  turns a broken write into a plausible test result. Anything this harness writes for the
  game to read is now read back and parsed before the run continues.
- **The quoting boundary is where to look.** `lib/ssh-omen.sh` already says a script file
  exists so "quoting and encoding issues never make it across the SSH boundary" - and this
  was written inline anyway. Anything with quotes in it goes in a `.ps1`.
- **Topology split the symptom.** Passing in one topology and failing in the other pointed
  at the mod's two code paths; it was really two *config* paths, only one of which the
  harness wrote correctly.

## "Everything passed" and `ok: false` at the same time

The release gate reported this after a run in which every single stage printed "verification
passed":

```json
{"status":"ok","packaged_config":"identical","ok":false,"failed":[]}
```

`failed` was empty *and* `ok` was false, which cannot both be about the same thing. The
summary was right and the gate expression was wrong:

```jq
[.[] | select(.ok | not)] | length == 0 and (. | length) > 0
```

After the pipe, `.` is the *filtered* list. With nothing failing that list is empty, so
"length == 0" was true and "more than zero stages ran" was false - asked of the wrong list.
Written the other way round it says what was meant:

```jq
(length > 0) and ([.[] | select(.ok | not)] | length == 0)
```

Worth keeping in general: after a `|` in jq, `.` is whatever the previous stage produced, and
a second question about "the input" silently becomes a question about the intermediate. The
tell was the contradiction in the output - a summary that lists no failures next to a verdict
that says it failed is a bug in the verdict, not in the run.

## A checklist that assumes an empty world breaks when it is not the only test

Paging asserted "six destinations: five on the first page, one on the second", which was true
when it was the only thing running. Inside the release gate it ran after the dialog, travel,
companion and distance stages, all of which record traders of their own, and it failed on a
list that was longer than it expected - while the pager itself was working perfectly.

The scenario now walks every page to the end and checks the properties that hold whatever the
total is: every page but the last is full, the last is neither empty nor overfull, nothing
appears twice or goes missing, the controls match the position in the list, and going back
lands on the page before. Seven recorded traders became the *minimum* rather than the answer.

The general shape: a check that encodes "the world contains exactly what I just put in it"
only works while the scenario runs alone. Assert the invariant, not the arithmetic of one
particular fixture.

## A release that is "one command" except for the parts that are not

The August 2026 release was published with scripts, and still took a dozen hand-typed steps:
two file ids and a category read out of the runbook, a changelog extracted from the other
branch with `git show`, release notes pasted together from the CHANGELOG, a sentence naming
the other line's current version typed from memory, and afterwards a browser to archive a file
the upload had left in the wrong section.

Each of those is a place to be wrong, and one of them was: the "use the 0.6.22 release
instead" line in a release note is only right until the other line moves.

`bin/release.sh` now takes a line name and does the rest, reading everything else from the
commit being released. The rule it encodes: **anything a human would look up is something the
tool can look up.** The ids live in a committed config; the version comes from ModInfo.xml;
the notes come from CHANGELOG.md; the cross-reference comes from the other branch.

Two smaller things fell out of writing it:

- **Preflight before the expensive part.** Missing changelog, unauthenticated `gh`, a branch
  behind origin, a tag already released - all cheap to check, all discovered after a
  twenty-minute verification if you do not.
- **A rehearsal must not damage the thing it rehearses.** `--dry-run` originally rebuilt the
  package, and two builds of one commit are not byte-identical, so it replaced a verified ZIP
  with an unverified twin of the same name. It now keeps what is there.

And the thing that started it, which took two attempts to diagnose correctly. The first
reading was "0.6.22 was uploaded as its own file rather than as a version of 7403906" - the
mod's edit page lists it as its own row, which looked like proof. The API says otherwise:
0.6.22 was always a version of 7403906, and it stayed listed as `optional` after 0.6.23 was
added.

The actual rule is that **`main` is exclusive and `optional` is not**. Nexus retires the
previous main version by itself because there can only be one; an optional file keeps every
current version on the page. So the 3.x line looked after itself and the v2.6 line did not,
and the difference was never about how the files had been uploaded.

There is no endpoint for changing a version's category afterwards - `/mod-file-versions/{id}`
is read-only. The only handle is at creation time: `previous_version_id`, "the version this
one replaces", which `bin/publish-to-nexus.sh` now fills in by looking up the file's current
version. Whether Nexus then retires it is something the next release will show, which is why
`bin/check-nexus-page.sh` runs afterwards and says plainly what the page looks like.

Worth keeping: **the editing UI is not the data model.** A row in the file list looked like a
separate file and was not, and a diagnosis built on that would have "fixed" the wrong thing.

## An environment variable the config quietly overwrote

A scenario was launched to test a feature branch:

```bash
VTT_BRANCH=feature/58-forget-destination ./bin/run-scenario-check.sh --scenario forget --profile v3
```

It built `main`. `load_profile` sources `config/v3.env`, which sets `VTT_BRANCH=main`, and
sourcing happens after the environment is set - so the profile won, silently. The run then
reported that the new dialog screen never appeared, which is exactly what "the feature does
not work" looks like.

The first instinct was to go and read the mod code again. What actually settled it was that
the failure was too complete: the screen did not appear *at all*, not even wrongly. Code that
is written and compiled usually fails partially; code that is absent fails totally.

`load_profile` now saves the variables listed in `PROFILE_OVERRIDABLE_VARS`, sources the
profile, and puts them back - logging that it did, so the override is visible in the run's own
output rather than being something to remember.

Worth generalising: **a config file that is sourced after the environment silently outranks
it**, which is the opposite of what every caller expects. Either let the environment win or
refuse the override loudly; quietly ignoring it produces a test that reports on the wrong
build.

## The game negotiates package ids by name, and denies entry when it cannot

Adding a sixth net package to the mod produced logs where client and server had
assigned *different* ids to the same package types. That looked like a serious bug:
if the ids differ, a "snapshot request" would arrive as a "visit report" and be
read as a different structure entirely - silent corruption of a save file.

It is not what happens, and the reasoning that led there was wrong in an
instructive way. Decompiling `NetPackageManager` settled it:

```csharp
// StartServer() assigns 1..N. StartClient() starts with an empty table.
// IdMappingsReceived(string[] names) fills the client's table from the server's:
if (!knownPackageTypes.TryGetValue(_mappings[i], out var value))
{
    Log.Error("[NET] Unknown package type " + _mappings[i] + ", can not proceed connecting to server");
    ConnectionManager.Instance.Disconnect();
    GameManager.Instance.ShowMessagePlayerDenied(new KickPlayerData(EKickReason.UnknownNetPackage));
    break;
}
```

The ids logged at startup are the mod registering itself; **they are overwritten at
connect by the server's table**. So after connecting the two sides always agree, and
mis-dispatch cannot happen. What the logs showed was real and completely irrelevant.

Three things fell out that matter more than the original question:

- **A client without the mod cannot join a server that has it.** The server's name list
  contains types a vanilla client has never heard of, so it is denied entry. That is a
  property of every mod with custom net packages, and it was not written down anywhere.
- **Adding a package type locks out every client that has not updated.** Same mechanism.
  A server admin who updates first denies entry to all their players.
- **The game checks names, not versions or formats.** Two builds with identical package
  names connect happily and mis-read each other's payloads. That gap is real for this mod,
  which changed its destination-key format once already.

Worth keeping: **an observation can be entirely correct and still support a wrong
conclusion.** The differing ids were really there in the logs. The error was assuming
they were the ids that would be used, rather than asking where ids come from. Reading the
mechanism took one decompile; reasoning about it had already burned an hour and produced
a design for a problem that does not exist.

## Measure the mismatch instead of arguing about it

Several rounds of design went into "how should the mod detect a version mismatch", all of
it resting on unverified guesses about how the game frames packages. The argument could
not converge because nobody had run one.

`bin/03-deploy-mods.sh` now takes `VTT_SERVER_RELEASE_PACKAGE`, which deploys a *different*
build to the server than to the client. One run answered what an hour of reasoning had
not: the client connects, the CRC does not care, and the ids come from the server.

The general form, which this pipeline keeps re-learning: when a design debate depends on
how the platform behaves, the cheapest move is to make the platform show you. The rig to
do it is usually smaller than the argument, and it becomes the regression test afterwards.
