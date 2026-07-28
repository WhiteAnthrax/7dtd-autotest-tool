#Requires -Version 5.1
<#
.SYNOPSIS
    Reports the compatibility version of the client that was just launched, by reading it
    back out of Player.log.

.DESCRIPTION
    There is no version file in the game install to read ahead of time - the exe's
    ProductVersion is Unity's (2022.3.x), not the game's - so the only dependable source
    is the client's own log line, written about 0.07s into startup:

        INF Version: V 3.1.0 (b13) Compatibility Version: V 3.1.0, Build: WindowsPlayer 64 Bit

    Unity keys Player.log by company/product name, so every 7DTD install on the machine
    writes to the *same* file. A stale line from a previous launch (possibly of a
    different profile's client) would therefore be easy to read by mistake, so this only
    trusts a log that has been written to recently. Freshness is judged entirely against
    this machine's own clock - never against a timestamp passed in from the Linux side,
    which would break on any clock skew between the two.

.OUTPUTS
    "COMPATIBILITY <version>" once a fresh log yields one, or "TIMEOUT" if none appears.
    Exits 0 either way: the caller decides how strict to be, and a version it could not
    determine should not be fatal on its own.
#>
param(
    [int]$TimeoutSeconds = 60,
    [int]$MaxLogAgeSeconds = 180,
    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $LogPath) {
    $LogPath = Join-Path $env:USERPROFILE 'AppData\LocalLow\The Fun Pimps\7 Days To Die\Player.log'
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $LogPath) {
        $item = Get-Item $LogPath
        if (((Get-Date) - $item.LastWriteTime).TotalSeconds -lt $MaxLogAgeSeconds) {
            $match = Select-String -Path $LogPath -Pattern 'Compatibility Version: V ([^,]+)' |
                Select-Object -First 1
            if ($match) {
                Write-Output "COMPATIBILITY $($match.Matches[0].Groups[1].Value.Trim())"
                exit 0
            }
        }
    }
    Start-Sleep -Milliseconds 500
}

Write-Output "TIMEOUT"
