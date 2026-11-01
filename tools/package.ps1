# Builds the native DLL and variants-reverter (Release) and packages a release zip:
#   dist/forged-and-found-<version>.zip
#     forged-and-found/    the ShroudForge mod folder (copy into <game>/mods/)
#     variants-reverter/   the save converter for removing the mod, with its variant map
#     README.md, LICENSE
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
$stage = Join-Path $dist "forged-and-found-$version"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# Mod folder: package files only (no local flag files such as marker.enabled).
$modOut = Join-Path $stage 'forged-and-found'
New-Item -ItemType Directory -Force -Path $modOut | Out-Null
foreach ($item in 'mod.json', 'extended.mod.json', 'native-plugin.ini', 'src', 'data', 'bin') {
    Copy-Item -Recurse (Join-Path $mod $item) $modOut
}

$revOut = Join-Path $stage 'variants-reverter'
New-Item -ItemType Directory -Force -Path $revOut | Out-Null
Copy-Item (Join-Path $root 'native\build\reverter-Release\variants-reverter.exe') $revOut
Copy-Item (Join-Path $root 'native\variants-reverter\variant-map.txt') $revOut

Copy-Item (Join-Path $root 'README.md'), (Join-Path $root 'LICENSE') $stage

$zip = Join-Path $dist "forged-and-found-$version.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
'{0}  {1:N0} bytes  SHA-256 {2}' -f $zip, (Get-Item $zip).Length, (Get-FileHash $zip).Hash
