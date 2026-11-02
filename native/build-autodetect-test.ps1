# Builds autodetect-test.exe (checks the DLL's auto-detection rules against a stored game
# executable). Usage: ./native/build-autodetect-test.ps1
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -products * -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC Build Tools not found (vswhere)' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$env:PATH = "$(Split-Path $vswhere);$env:PATH"

$obj = Join-Path $PSScriptRoot 'build\autodetect-test'
New-Item -ItemType Directory -Force -Path $obj | Out-Null
$exe = Join-Path $obj 'autodetect-test.exe'
$log = Join-Path $obj 'build.log'
$cmd = "cl /nologo /std:c++17 /W4 /WX /EHsc /MT /O2 /DUNICODE /D_UNICODE `"$PSScriptRoot\autodetect-test\main.cpp`" " +
       "/Fo`"$obj\\`" /Fe`"$exe`" /link /INCREMENTAL:NO"
cmd /c "call `"$vcvars`" >nul && ($cmd) > `"$log`" 2>&1"
if ($LASTEXITCODE -ne 0) { Get-Content $log | Select-String -Pattern 'error|warning' | Select-Object -First 30; throw "build failed, see $log" }
$exe
