#Requires -Version 5.1
<#
.SYNOPSIS
    Disables the game's Discord integration before a test run (Apply), and puts the
    previous settings back afterwards (Restore), so an automated run is never blocked by
    Discord's main-menu modals.

.DESCRIPTION
    Why this exists: DiscordManager registers a handler on ModEvents.MainMenuOpening and,
    unless Discord is disabled, returns EModEventResult.StopHandlersAndVanilla after
    opening either the Discord login window or (on an account that has never seen it) the
    first-time info dialog. StopHandlersAndVanilla suppresses the vanilla main-menu open
    entirely, so XUiC_MainMenu.OnOpen never runs, ModEvents.MainMenuOpened never fires,
    and SdtdTestPilot's MainMenuTrigger never gets a chance to drive the client. The
    result looks exactly like a generic hang: the process stays alive and Responding, but
    Player.log simply stops. The only in-code escape is the setting this script writes.

    A launch argument cannot do this: DiscordManager reads the setting before
    GameStartupHelper.ApplyParsedGamePrefs() applies any command-line GamePrefs override
    (verified on real hardware - see docs/lessons-learned.md).

    TWO STORAGE FORMATS, and a machine running both game lines needs both:
      * v3.x keeps it as its own GamePref, registry value "DiscordDisabled_h<hash>" (DWORD).
      * v2.6 keeps it inside a JSON blob in the registry value "DiscordSettings_h<hash>"
        (REG_BINARY: UTF-8 JSON with a trailing NUL). v3.x treats that blob as legacy: it
        migrates it once and then DELETES it. So every v3 run wipes the setting v2.6 reads,
        and the next v2.6 run silently falls back to "Discord enabled" and hangs.
    This script writes whichever formats are relevant so the order of profile runs on a
    shared machine stops mattering.

    The registry setting is stored per Unity company/product name, so every 7DTD install
    on the machine shares it regardless of which folder it was launched from - which is
    exactly why the v3/v2.6 interaction above bites. There is nothing per-profile here.

.PARAMETER Mode
    Apply   - back up the current state to BackupPath, then disable Discord.
    Restore - put the state in BackupPath back, then delete BackupPath.

.PARAMETER ExpectedUser
    The Windows account the client is expected to run as. Registry writes land in the
    HKCU hive of whoever runs this script, while the client itself runs as a scheduled
    task under OMEN_USER_ID. If those differ the write silently lands in the wrong hive
    and has no effect on the client, so this mismatch is a hard error rather than
    something to rediscover later as another mystery hang.

.PARAMETER BackupPath
    Where the previous state is stored between Apply and Restore, on this machine.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('Apply', 'Restore')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$ExpectedUser,
    [Parameter(Mandatory = $true)][string]$BackupPath,
    [string]$SubKey = 'Software\The Fun Pimps\7 Days To Die'
)

$ErrorActionPreference = 'Stop'

if ($env:USERNAME -ne $ExpectedUser) {
    Write-Error "Registry hive mismatch: running as '$env:USERNAME' but the client runs as '$ExpectedUser'. A write here would land in the wrong HKCU hive and silently not affect the client."
    exit 1
}

# Use the .NET registry API rather than the PowerShell registry provider. This key holds
# 300+ values, some of a type Get-ItemProperty cannot cast, and it fails on the *whole
# key* - which reads as "the value isn't there" and sent an earlier investigation off
# looking for a config file that does not exist. GetValueNames()/GetValue() are fine.
$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $true)
if ($null -eq $key) {
    Write-Error "Registry key not found: HKCU\$SubKey. Has the game ever been launched on this account?"
    exit 1
}

# Unity's PlayerPrefs mangles each key name into "<name>_h<hash>", so neither value can be
# addressed by its plain name. Discover the real names rather than assuming the hashes:
# they are deterministic per key name, but matching what is actually present keeps this
# working if that ever stops being true.
function Find-ValueName([string]$prefix, [string]$fallback) {
    $found = $key.GetValueNames() | Where-Object { $_ -like "$prefix`_h*" } | Select-Object -First 1
    if ($found) { return $found }
    return $fallback
}

$dwordName = Find-ValueName 'DiscordDisabled' 'DiscordDisabled_h2080590481'
$jsonName = Find-ValueName 'DiscordSettings' 'DiscordSettings_h1795906148'

function Get-JsonBlob {
    $raw = $key.GetValue($jsonName)
    if ($null -eq $raw) { return $null }
    # Unity stores string prefs as UTF-8 bytes with a trailing NUL.
    return [System.Text.Encoding]::UTF8.GetString($raw).TrimEnd([char]0)
}

function Set-JsonBlob([string]$text) {
    $utf8 = [System.Text.Encoding]::UTF8.GetBytes($text)
    # Build the trailing NUL into a real byte[]: "$utf8 + [byte]0" would produce an
    # Object[], which SetValue rejects for RegistryValueKind::Binary.
    $bytes = New-Object 'byte[]' ($utf8.Length + 1)
    [Array]::Copy($utf8, $bytes, $utf8.Length)
    $bytes[$utf8.Length] = 0
    $key.SetValue($jsonName, $bytes, [Microsoft.Win32.RegistryValueKind]::Binary)
}

try {
    if ($Mode -eq 'Apply') {
        $state = [ordered]@{
            dword = if ($key.GetValueNames() -contains $dwordName) { [int]$key.GetValue($dwordName) } else { $null }
            json  = Get-JsonBlob
        }
        $backupDir = Split-Path -Parent $BackupPath
        if ($backupDir -and -not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        }
        $state | ConvertTo-Json -Compress | Set-Content -Path $BackupPath -Encoding UTF8

        $key.SetValue($dwordName, 1, [Microsoft.Win32.RegistryValueKind]::DWord)

        # Patch the blob in place so the player's audio devices/volumes survive; only
        # synthesize one when there is none, in which case the game would have used these
        # same defaults anyway. -replace is case-insensitive, which is what we want here.
        $json = $state.json
        if ($null -eq $json) {
            $json = '{"DiscordFirstTimeInfoShown":true,"DiscordDisabled":true,"LastAccountType":0,"AccessToken":null,"RefreshToken":null,"selectedOutputDevice":"default","selectedInputDevice":"default","outputVolume":100,"inputVolume":100,"voiceModePtt":false,"voiceVadModeAuto":true,"voiceVadThreshold":-60,"dmPrivacyMode":true,"autoJoinVoiceMode":0}'
        } else {
            $json = $json -replace '"DiscordDisabled"\s*:\s*false', '"DiscordDisabled":true'
        }
        Set-JsonBlob $json

        Write-Output "APPLIED previous_dword=$($state.dword) had_json=$([bool]$state.json)"
    } else {
        if (-not (Test-Path $BackupPath)) {
            Write-Output "NOBACKUP"
            exit 0
        }
        $state = Get-Content -Path $BackupPath -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($null -ne $state.dword) {
            $key.SetValue($dwordName, [int]$state.dword, [Microsoft.Win32.RegistryValueKind]::DWord)
        } else {
            $key.DeleteValue($dwordName, $false)
        }

        if ($null -ne $state.json) {
            Set-JsonBlob $state.json
        } else {
            # There was no blob before; v3.x deletes it as part of its legacy migration, so
            # "absent" is a state worth restoring faithfully.
            $key.DeleteValue($jsonName, $false)
        }

        Remove-Item -Path $BackupPath -Force
        Write-Output "RESTORED dword=$($state.dword) had_json=$($null -ne $state.json)"
    }
} finally {
    $key.Close()
}
