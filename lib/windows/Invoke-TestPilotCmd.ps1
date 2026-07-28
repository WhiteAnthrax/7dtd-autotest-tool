#Requires -Version 5.1
<#
.SYNOPSIS
    Submits one command to a running SdtdTestPilot command queue and waits for its result.

.DESCRIPTION
    Writes <QueueDir>\in\<Id>.cmd atomically (tmp file + rename, per
    docs/HeadlessTestDriver.md's protocol), then polls <QueueDir>\out\<Id>.result until it
    appears and prints it to stdout as "B64 <base64 of the file's bytes>".

    The base64 is not decoration: the result file is UTF-8 (SdtdTestPilot writes it with
    UTF8Encoding(false)), but this is a Japanese-locale Windows host. `Get-Content` without
    -Encoding reads a BOM-less file using the ANSI code page (CP932), and anything written
    to stdout is re-encoded through [Console]::OutputEncoding on its way out over SSH.
    Either step mangles localized game text and leaves the JSON as invalid UTF-8 that jq
    rejects outright (observed as `jq: exit 5` on a dialog dump full of Japanese). Passing
    the raw bytes through base64 makes the transport independent of every locale and
    console-encoding setting on both ends.
#>
param(
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string]$QueueDir,
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$tmp = Join-Path $QueueDir "in\$Id.cmd.tmp"
$final = Join-Path $QueueDir "in\$Id.cmd"
[System.IO.File]::WriteAllText($tmp, $Command)
Rename-Item -Path $tmp -NewName "$Id.cmd"

$resultPath = Join-Path $QueueDir "out\$Id.result"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $resultPath) {
        $bytes = [System.IO.File]::ReadAllBytes($resultPath)
        Write-Output ('B64 ' + [Convert]::ToBase64String($bytes))
        exit 0
    }
    Start-Sleep -Milliseconds 300
}
Write-Output "TIMEOUT waiting for $resultPath"
exit 1
