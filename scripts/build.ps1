<#
.SYNOPSIS
Build all retake plugins with pinned AMX Mod X and ReAPI dependencies on Windows.
.DESCRIPTION
Compiler warnings fail the build by default. Use -AllowWarnings only for a legacy baseline.
.EXAMPLE
pwsh -File scripts/build.ps1
.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts/build.ps1 -ToolchainDirectory C:\amxx-build
#>
[CmdletBinding()]
param(
    [string]$ToolchainDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) '.toolchain'),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'build'),
    [switch]$AllowWarnings
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot

function Install-VerifiedArchive {
    param([string]$Name, [string]$Url, [string]$Sha256)

    $archive = Join-Path $ToolchainDirectory "$Name.zip"
    $destination = Join-Path $ToolchainDirectory $Name
    if (-not (Test-Path -LiteralPath $archive)) {
        Write-Host "Downloading $Name"
        Invoke-WebRequest -Uri $Url -OutFile "$archive.download" -UseBasicParsing
        $downloadHash = (Get-FileHash -LiteralPath "$archive.download" -Algorithm SHA256).Hash
        if ($downloadHash -ne $Sha256) {
            throw "Checksum mismatch for $Name download. Expected $Sha256, got $downloadHash."
        }
        Move-Item -LiteralPath "$archive.download" -Destination $archive
    }
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($archiveHash -ne $Sha256) {
        throw "Checksum mismatch for cached $archive. Remove that archive and retry."
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
}

New-Item -ItemType Directory -Path $ToolchainDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$ToolchainDirectory = (Resolve-Path -LiteralPath $ToolchainDirectory).Path
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

Install-VerifiedArchive -Name 'amxx-5486' `
    -Url 'https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5486/amxmodx-1.10.0-git5486-base-windows.zip' `
    -Sha256 '9016824AC5AE0751E1AA9647AD9A506FCF4AF6E63AD1CCF5DD7769025B00C6A0'
Install-VerifiedArchive -Name 'reapi-5.29.0.358' `
    -Url 'https://github.com/rehlds/ReAPI/releases/download/5.29.0.358/reapi-bin-5.29.0.358.zip' `
    -Sha256 'F33A7435540BEA8706DB3FA948E51A85B511F5B18C383B97402A204DC5419195'

$scripting = Join-Path $ToolchainDirectory 'amxx-5486/addons/amxmodx/scripting'
$compiler = Join-Path $scripting 'amxxpc.exe'
$amxxIncludes = Join-Path $scripting 'include'
$reapiIncludes = Join-Path $ToolchainDirectory 'reapi-5.29.0.358/addons/amxmodx/scripting/include'

foreach ($plugin in @('retake_core', 'retake_map', 'retake_editor')) {
    $source = Join-Path $repository "$plugin.sma"
    $output = Join-Path $OutputDirectory "$plugin.amxx"
    $log = Join-Path $OutputDirectory "$plugin.log"
    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output
    }
    & $compiler $source "-i$amxxIncludes" "-i$reapiIncludes" "-i$repository" "-o$output" 2>&1 |
        Tee-Object -FilePath $log
    $compilerExit = $LASTEXITCODE
    if ($compilerExit -ne 0 -or -not (Test-Path -LiteralPath $output)) {
        throw "Compilation failed for $plugin (exit $compilerExit). See $log."
    }
    if (-not $AllowWarnings -and (Select-String -LiteralPath $log -Pattern '\bwarning [0-9]+:' -Quiet)) {
        throw "Compiler warnings in $plugin. Fix the warnings or use -AllowWarnings for a legacy baseline. See $log."
    }
}

Write-Host "Built all three plugins in $OutputDirectory"
