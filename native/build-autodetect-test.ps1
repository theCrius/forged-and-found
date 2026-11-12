# Builds autodetect-test.exe (checks the DLL's auto-detection rules against a stored game
# executable). Usage: ./native/build-autodetect-test.ps1
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'msvc.ps1')  # pinned MSVC toolset, the DLL's compiler
$vcvars = Get-PinnedVcvars

$obj = Join-Path $PSScriptRoot 'build\autodetect-test'
New-Item -ItemType Directory -Force -Path $obj | Out-Null
$exe = Join-Path $obj 'autodetect-test.exe'
$log = Join-Path $obj 'build.log'
$cmd = "cl /nologo /std:c++17 /W4 /WX /EHsc /MT /O2 /DUNICODE /D_UNICODE `"$PSScriptRoot\autodetect-test\main.cpp`" " +
       "/Fo`"$obj\\`" /Fe`"$exe`" /link /INCREMENTAL:NO"
cmd /c "call `"$vcvars`" -vcvars_ver=$Toolset >nul && ($cmd) > `"$log`" 2>&1"
if ($LASTEXITCODE -ne 0) { Get-Content $log | Select-String -Pattern 'error|warning' | Select-Object -First 30; throw "build failed, see $log" }
$exe
