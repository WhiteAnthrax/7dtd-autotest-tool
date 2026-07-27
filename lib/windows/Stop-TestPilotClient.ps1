#Requires -Version 5.1
<#
.SYNOPSIS
    Stops the client process and removes the scheduled task created by
    Start-TestPilotClient.ps1.
#>
param(
    [Parameter(Mandatory = $true)][string]$ProcessName,
    [Parameter(Mandatory = $true)][string]$TaskName
)

$ErrorActionPreference = 'Stop'

Stop-Process -Name $ProcessName -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Output "STOPPED"
