# Builds the native DLL and variants-reverter (Release) and packages two release zips:
#   dist/forged-and-found-<version>.zip   the mod: forged-and-found/ (copy into <game>/mods/),
#                                         README.md, LICENSE. Holds no .exe: Nexus Mods blocks
#                                         uploads with one inside.
#   dist/variants-reverter-<version>.zip  the save converter for removing the mod, with its
#                                         variant map, a how-to and the licenses it needs
# Each also as a copy without the version, so .../releases/latest/download/<name>.zip always
# points at the newest release.
# The version comes from mods/forged-and-found/mod.json. When run for a git tag (CI sets
# GITHUB_REF_TYPE=tag), the tag must be v<version>.
# Usage: ./tools/package.ps1
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$mod = Join-Path $root 'mods\forged-and-found'
$version = (Get-Content -Raw (Join-Path $mod 'mod.json') | ConvertFrom-Json).version
if ($env:GITHUB_REF_TYPE -eq 'tag' -and $env:GITHUB_REF_NAME -ne "v$version") {
    throw "tag $($env:GITHUB_REF_NAME) does not match mod.json version $version"
}

& (Join-Path $root 'native\build.ps1') -Config Release
& (Join-Path $root 'native\build-reverter.ps1') -Config Release

$dist = Join-Path $root 'dist'

function New-Stage([string]$name) {
    $stage = Join-Path $dist "$name-$version"
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $stage
}

function Save-Zip([string]$name, [string]$stage) {
    $zip = Join-Path $dist "$name-$version.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
    '{0}  {1:N0} bytes  SHA-256 {2}' -f $zip, (Get-Item $zip).Length, (Get-FileHash $zip).Hash
    Copy-Item $zip (Join-Path $dist "$name.zip") -Force
}

# The mod: package files only.
$modStage = New-Stage 'forged-and-found'
$modOut = Join-Path $modStage 'forged-and-found'
New-Item -ItemType Directory -Force -Path $modOut | Out-Null
foreach ($item in 'mod.json', 'extended.mod.json', 'native-plugin.ini', 'src', 'data', 'bin') {
    Copy-Item -Recurse (Join-Path $mod $item) $modOut
}
Copy-Item (Join-Path $root 'README.md'), (Join-Path $root 'LICENSE') $modStage
$forbidden = @(Get-ChildItem -Path $modStage -Recurse -File -Filter '*.exe')
if ($forbidden.Count) { throw "the mod zip must hold no .exe (Nexus Mods blocks it): $($forbidden.Name -join ', ')" }
Save-Zip 'forged-and-found' $modStage

# The save converter.
$revStage = New-Stage 'variants-reverter'
$revOut = Join-Path $revStage 'variants-reverter'
New-Item -ItemType Directory -Force -Path $revOut | Out-Null
Copy-Item (Join-Path $root 'native\build\reverter-Release\variants-reverter.exe') $revOut
Copy-Item (Join-Path $root 'native\variants-reverter\variant-map.txt') $revOut
Copy-Item (Join-Path $root 'native\variants-reverter\README.txt') $revOut
Copy-Item (Join-Path $root 'LICENSE') $revOut
Copy-Item (Join-Path $root 'native\third_party\zstd\LICENSE') (Join-Path $revOut 'LICENSE-zstd')
Save-Zip 'variants-reverter' $revStage
