#Requires -Version 5.1
<#
.SYNOPSIS
    Submits one command to a running SdtdTestPilot command queue and waits for its result.

.DESCRIPTION
    Writes <QueueDir>\in\<Id>.cmd atomically (tmp file + rename, per
    docs/HeadlessTestDriver.md's protocol), then polls <QueueDir>\out\<Id>.result until it
    appears and prints its contents (single-line JSON) to stdout.
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
        Get-Content $resultPath -Raw
        exit 0
    }
    Start-Sleep -Milliseconds 300
}
Write-Output "TIMEOUT waiting for $resultPath"
exit 1
