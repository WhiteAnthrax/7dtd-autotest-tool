#Requires -Version 5.1
<#
.SYNOPSIS
    Launches the 7DTD client under SdtdTestPilot via Scheduled Tasks (Start-Process fails
    silently over a non-interactive SSH session - see docs/lessons-learned.md).

.DESCRIPTION
    -WorkingDirectory is NOT optional: without it, Unity fails to resolve
    Data/Addressables/*.bundle by its relative path, the client hangs forever on
    "Loading Game data..." with no crash and no obvious log error, and it is easy to
    mistake for a mod bug. Always pass the folder the exe lives in.

    Registering with -Force replaces any prior task/action wholesale, since reusing
    Set-ScheduledTask's Action alone can silently drop the Principal and cause the same
    "starts and instantly exits" failure this script exists to avoid.
#>
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$Arguments,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [Parameter(Mandatory = $true)][string]$TaskName,
    [Parameter(Mandatory = $true)][string]$UserId
)

$ErrorActionPreference = 'Stop'

$action = New-ScheduledTaskAction -Execute $ExePath -Argument $Arguments -WorkingDirectory $WorkingDirectory
$principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive
Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3

$exeName = [System.IO.Path]::GetFileNameWithoutExtension($ExePath)
$proc = Get-Process -Name $exeName -ErrorAction SilentlyContinue
if (-not $proc) {
    Write-Error "Process '$exeName' is not running after starting scheduled task '$TaskName'."
    exit 1
}
Write-Output "STARTED pid=$($proc.Id)"
