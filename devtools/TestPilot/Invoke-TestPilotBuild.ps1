#Requires -Version 5.1
<#
.SYNOPSIS
    Development-only build/deploy helper for the SdtdTestPilot mod.

.DESCRIPTION
    Builds src\SdtdTestPilot\SdtdTestPilot.csproj (and its unit tests), then optionally copies
    the resulting DLL and ModInfo.xml into a client Mods folder. This is intentionally separate
    from devtools\Invoke-WindowsBuild.ps1, which is scoped to the VisitedTraderTeleport mod only
    and is not modified by this script or its addition to the repository.

    SdtdTestPilot is a test-only driver: it auto-connects or auto-hosts on startup via
    -testpilot.* command-line flags and executes console commands injected via local files.
    Never copy it into a Mods folder used against a real/public server. See
    docs\HeadlessTestDriver.md.

.PARAMETER RepositoryPath
    Root of the VisitedTraderTeleport repository. Defaults to two levels above this script.

.PARAMETER GamePath
    7 Days To Die installation root, used to resolve refs\managed and refs\harmony source DLLs.
    Defaults to the VTT_GAME_PATH environment variable.

.PARAMETER Configuration
    Debug or Release. SdtdTestPilot only does anything at runtime in a Debug build
    (TESTPILOT_ENABLED). Defaults to Debug.

.PARAMETER DotNetPath
    Path to the dotnet executable. Defaults to VTT_DOTNET_PATH, then 'dotnet' on PATH.

.PARAMETER ClientModsDir
    If supplied, the built DLL and ModInfo.xml are copied into
    "<ClientModsDir>\SdtdTestPilot\" after a successful build. Omit to build only.

.PARAMETER SkipTests
    Skip "dotnet test" for SdtdTestPilot.Tests.

.PARAMETER GameFlavor
    Which game-version-specific API shape to compile against: 'v3' (7DTD 3.0, default) or
    'v26' (7DTD v2.6, where a handful of API members differ - see AutoSpawnDriver.cs).

.EXAMPLE
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Invoke-TestPilotBuild.ps1 `
        -GamePath 'D:\GAMES\7D2D\Custom\3.0Vanilla' -ClientModsDir 'D:\GAMES\7D2D\Custom\3.0Vanilla\Mods'

.EXAMPLE
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Invoke-TestPilotBuild.ps1 `
        -GamePath 'D:\GAMES\7D2D\v2\The_Wasteland\The_Wasteland' -GameFlavor v26
#>
[CmdletBinding()]
param(
    [string]$RepositoryPath,
    [string]$GamePath = $env:VTT_GAME_PATH,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [string]$DotNetPath = $(if ($env:VTT_DOTNET_PATH) { $env:VTT_DOTNET_PATH } else { 'dotnet' }),
    [string]$ClientModsDir,
    [switch]$SkipTests,
    [ValidateSet('v3', 'v26')]
    [string]$GameFlavor = 'v3'
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably populated while default parameter values are evaluated when
# invoked via `powershell.exe -File`, so resolve the default here instead.
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
    $RepositoryPath = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Write-Log {
    param([string]$Message)
    Write-Host ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message)
}

function Get-ReferencePlan {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$GamePath,
        [Parameter(Mandatory = $true)][string]$BuildRepository
    )

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
        if ($hintPath -match '(^|\\)refs\\managed\\([^\\]+)$') {
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
                Name                  = $fileName
                Source                = (Resolve-Path -LiteralPath $source).Path
                DestinationDirectory  = $destinationDirectory
                Destination           = Join-Path $destinationDirectory $fileName
            }
        }
    }
    return , $plan
}

if ([string]::IsNullOrWhiteSpace($GamePath)) {
    throw 'GamePath was not supplied and VTT_GAME_PATH is not set.'
}
if (-not (Test-Path -LiteralPath $GamePath -PathType Container)) {
    throw "GamePath does not exist: '$GamePath'."
}

$projectPath = Join-Path $RepositoryPath 'src\SdtdTestPilot\SdtdTestPilot.csproj'
$testsProjectPath = Join-Path $RepositoryPath 'tests\SdtdTestPilot.Tests\SdtdTestPilot.Tests.csproj'
$modOutputDir = Join-Path $RepositoryPath 'mod\SdtdTestPilot'

Write-Log "Resolving game reference DLLs from '$GamePath'..."
$referencePlan = Get-ReferencePlan -ProjectPath $projectPath -GamePath $GamePath -BuildRepository $RepositoryPath
foreach ($reference in $referencePlan) {
    [void][System.IO.Directory]::CreateDirectory($reference.DestinationDirectory)
    Copy-Item -LiteralPath $reference.Source -Destination $reference.Destination -Force
    Write-Log "Copied game reference: $($reference.Name)"
}

Write-Log "Building SdtdTestPilot ($Configuration, GameFlavor=$GameFlavor)..."
& $DotNetPath build $projectPath -c $Configuration "-p:GameFlavor=$GameFlavor"
if ($LASTEXITCODE -ne 0) {
    throw "dotnet build failed with exit code $LASTEXITCODE."
}

if ($SkipTests) {
    Write-Log 'Skipping dotnet test (requested via -SkipTests).'
}
else {
    Write-Log 'Running SdtdTestPilot.Tests...'
    & $DotNetPath test $testsProjectPath -c $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet test failed with exit code $LASTEXITCODE."
    }
}

if ($ClientModsDir) {
    $destination = Join-Path $ClientModsDir 'SdtdTestPilot'
    Write-Log "Deploying to '$destination'..."
    [void][System.IO.Directory]::CreateDirectory($destination)
    Copy-Item -LiteralPath (Join-Path $modOutputDir 'SdtdTestPilot.dll') -Destination $destination -Force
    Copy-Item -LiteralPath (Join-Path $modOutputDir 'ModInfo.xml') -Destination $destination -Force
    Write-Log 'Deployed. Remember: EnableTestPilot.txt must also exist in that folder before the mod does anything (see docs\HeadlessTestDriver.md).'
}

Write-Log 'Done.'
