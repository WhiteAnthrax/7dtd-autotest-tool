#Requires -Version 5.1
<#
.SYNOPSIS
    Enables (or disables) the mod's travel cost in an installed VisitedTraderTeleport.xml.

.DESCRIPTION
    A file, not an inline -Command string. The inline version wrote

        <TravelCost enabled=true item=casinoCoin ... />

    because the attribute quotes did not survive ssh -> powershell -Command, and the mod then
    logged "Could not read config, using Personal: 'true' is an unexpected token" and ran with
    its defaults. The scenario looked like the mod was ignoring the cost setting.

    So the replacement is built here, and the result is parsed back as XML before returning -
    a config this script leaves behind is valid or the run stops.
#>
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [Parameter(Mandatory = $true)][string]$Item,
    [Parameter(Mandatory = $true)][string]$PerMeter,
    [Parameter(Mandatory = $true)][string]$Minimum,
    [string]$Enabled = 'true'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Output "MISSING"
    exit 0
}

$replacement = '<TravelCost enabled="{0}" item="{1}" perMeter="{2}" minimum="{3}" />' -f `
    $Enabled, $Item, $PerMeter, $Minimum

$content = Get-Content -LiteralPath $ConfigPath -Raw
if ($content -notmatch '<TravelCost[^>]*/>') {
    throw "no <TravelCost .../> element in $ConfigPath"
}

# Plain -replace is safe here: the replacement carries no "$" for PowerShell to expand.
$updated = $content -replace '<TravelCost[^>]*/>', $replacement
Set-Content -LiteralPath $ConfigPath -Value $updated -NoNewline -Encoding UTF8

# Read it back rather than trusting the write: this is the check the inline version did not
# have, and its absence is the whole reason the scenario ran against a config the mod refused.
[xml]$parsed = Get-Content -LiteralPath $ConfigPath -Raw
$node = $parsed.SelectSingleNode('//TravelCost')
if ($null -eq $node) {
    throw "the rewritten $ConfigPath has no TravelCost element"
}

Write-Output ("PATCHED enabled={0} item={1} perMeter={2} minimum={3}" -f `
    $node.enabled, $node.item, $node.perMeter, $node.minimum)
