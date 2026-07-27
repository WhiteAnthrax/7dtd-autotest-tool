#Requires -Version 5.1
<#
.SYNOPSIS
    Generic Debug-build helper shared by VisitedTraderTeleport and SdtdTestPilot.

.DESCRIPTION
    Scans the target csproj's own Reference/HintPath entries for refs\managed,
    refs\harmony, and (v2.6 line) refs\_v2.6_backup\{managed,harmony} paths, copies the
    matching DLLs from GamePath, then runs `dotnet build -c Debug`.

    GameFlavor, if given, is passed as -p:GameFlavor=<value> to dotnet build (used by
    SdtdTestPilot.csproj's GAME_V26 define; VisitedTraderTeleport ignores it). It's a
    dedicated parameter rather than a generic pass-through array because -File's Win32
    command-line parsing can't reliably deliver a value starting with '-' (like
    "-p:GameFlavor=v26") into a [string[]] parameter - PowerShell's own binder mistakes
    it for the start of a new named parameter.
#>
param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [Parameter(Mandatory = $true)][string]$GamePath,
    [string]$RepositoryPath,
    [string]$GameFlavor,
    [string]$DotNetPath = 'dotnet'
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
    $RepositoryPath = (Resolve-Path (Join-Path (Split-Path $ProjectPath -Parent) '..\..')).Path
}

function Get-ReferencePlan {
    param([string]$ProjectPath, [string]$GamePath, [string]$BuildRepository)

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Leaf)) {
        throw "Target project file is missing: '$ProjectPath'."
    }
    [xml]$project = Get-Content -LiteralPath $ProjectPath -Raw

    $plan = @()
    $seen = @{}
    foreach ($node in @($project.SelectNodes('//Reference/HintPath'))) {
        $hintPath = $node.InnerText.Replace('/', '\')
        $sourceDirectory = $null
        $destinationDirectory = $null

        if ($hintPath -match '(^|\\)refs\\_v2\.6_backup\\managed\\([^\\]+)$') {
            $fileName = $Matches[2]
            $sourceDirectory = Join-Path $GamePath '7DaysToDie_Data\Managed'
            $destinationDirectory = Join-Path $BuildRepository 'refs\_v2.6_backup\managed'
        }
        elseif ($hintPath -match '(^|\\)refs\\_v2\.6_backup\\harmony\\([^\\]+)$') {
            $fileName = $Matches[2]
            $sourceDirectory = Join-Path $GamePath 'Mods\0_TFP_Harmony'
            $destinationDirectory = Join-Path $BuildRepository 'refs\_v2.6_backup\harmony'
        }
        elseif ($hintPath -match '(^|\\)refs\\managed\\([^\\]+)$') {
            $fileName = $Matches[2]
            $sourceDirectory = Join-Path $GamePath '7DaysToDie_Data\Managed'
            $destinationDirectory = Join-Path $BuildRepository 'refs\managed'
        }
        elseif ($hintPath -match '(^|\\)refs\\harmony\\([^\\]+)$') {
            $fileName = $Matches[2]
            $sourceDirectory = Join-Path $GamePath 'Mods\0_TFP_Harmony'
            $destinationDirectory = Join-Path $BuildRepository 'refs\harmony'
        }
        else {
            continue
        }

        $key = ($destinationDirectory + '\' + $fileName).ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $source = Join-Path $sourceDirectory $fileName
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Required game reference is missing: '$source'."
            }
            $plan += [PSCustomObject]@{
                Name                 = $fileName
                Source               = (Resolve-Path -LiteralPath $source).Path
                DestinationDirectory = $destinationDirectory
                Destination          = Join-Path $destinationDirectory $fileName
            }
        }
    }
    return , $plan
}

Write-Output "Resolving game reference DLLs from '$GamePath'..."
$referencePlan = Get-ReferencePlan -ProjectPath $ProjectPath -GamePath $GamePath -BuildRepository $RepositoryPath
foreach ($reference in $referencePlan) {
    [void][System.IO.Directory]::CreateDirectory($reference.DestinationDirectory)
    Copy-Item -LiteralPath $reference.Source -Destination $reference.Destination -Force
    Write-Output "Copied game reference: $($reference.Name)"
}

Write-Output "Building ($ProjectPath, Debug)..."
$buildArgs = @($ProjectPath, '-c', 'Debug')
if (-not [string]::IsNullOrWhiteSpace($GameFlavor)) {
    $buildArgs += "-p:GameFlavor=$GameFlavor"
}
& $DotNetPath build @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "dotnet build failed with exit code $LASTEXITCODE."
}
Write-Output "BUILD_OK"
