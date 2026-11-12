# Builds forged-and-found-native.dll with the MSVC Build Tools and puts it into the
# mod package (mods/forged-and-found/bin/), where native-plugin.ini points.
# Usage: ./native/build.ps1 [-Config Release|Debug] [-TestUnknownBuild]
# -TestUnknownBuild: a test DLL that ignores its known game builds, so auto-detection runs on the
# current game version. It goes to native/build/test-unknown-build/ and never into the package.
param([ValidateSet('Release', 'Debug')][string]$Config = 'Release', [switch]$TestUnknownBuild)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'msvc.ps1')  # pinned MSVC toolset
$vcvars = Get-PinnedVcvars

$src = Join-Path $PSScriptRoot 'forged-and-found-native'
$obj = Join-Path $PSScriptRoot $(if ($TestUnknownBuild) { 'build\test-unknown-build' } else { "build\$Config" })
$bin = Join-Path $PSScriptRoot '..\mods\forged-and-found\bin'
New-Item -ItemType Directory -Force -Path $obj, $bin | Out-Null
$dll = Join-Path $obj 'forged-and-found-native.dll'

# /MT: static CRT, so the DLL needs no Visual C++ runtime on the player's machine.
$opt = if ($Config -eq 'Release') { '/O2 /DNDEBUG' } else { '/Od /Zi' }
if ($TestUnknownBuild) { $opt += ' /DFF_TEST_UNKNOWN_BUILD' }
# /Brepro: no build timestamps, so the same source gives a byte-identical DLL.
$cl = "cl /nologo /std:c++17 /W4 /WX /EHsc /MT /Brepro $opt /DUNICODE /D_UNICODE /LD " +
      "`"$src\dllmain.cpp`" /Fo`"$obj\\`" /Fd`"$obj\\`" /Fe`"$dll`" /link /DLL /INCREMENTAL:NO /Brepro kernel32.lib"
$log = Join-Path $obj 'build.log'
cmd /c "call `"$vcvars`" -vcvars_ver=$Toolset >nul && ($cl) > `"$log`" 2>&1"
if ($LASTEXITCODE -ne 0) { Get-Content $log | Select-String -Pattern 'error|warning' | Select-Object -First 30; throw "build failed ($LASTEXITCODE), see $log" }
Assert-PinnedLinker $dll

if ($TestUnknownBuild) { $out = Get-Item $dll }
else {
    Copy-Item $dll $bin -Force
    $out = Get-Item (Join-Path $bin 'forged-and-found-native.dll')
}
'{0}  {1:N0} bytes  SHA-256 {2}  (MSVC {3})' -f $out.FullName, $out.Length, (Get-FileHash $out.FullName).Hash, $Toolset
