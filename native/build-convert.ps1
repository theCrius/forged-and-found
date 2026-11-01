# Builds perk-variants-convert.exe (offline save converter) with the MSVC Build Tools.
# zstd's decoder is compiled in from native/third_party/zstd (BSD); /MT links the CRT
# statically, so the exe runs without a Visual C++ runtime.
# Usage: ./native/build-convert.ps1 [-Config Release|Debug]
param([ValidateSet('Release', 'Debug')][string]$Config = 'Release')
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -products * -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC Build Tools not found (vswhere)' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$env:PATH = "$(Split-Path $vswhere);$env:PATH"

$src = Join-Path $PSScriptRoot 'perk-variants-convert'
$zstd = Join-Path $PSScriptRoot 'third_party\zstd'
$obj = Join-Path $PSScriptRoot "build\convert-$Config"
New-Item -ItemType Directory -Force -Path $obj | Out-Null
$exe = Join-Path $obj 'perk-variants-convert.exe'

$opt = if ($Config -eq 'Release') { '/O2 /DNDEBUG' } else { '/Od /Zi' }
$zsrc = @('common\debug.c', 'common\entropy_common.c', 'common\error_private.c', 'common\fse_decompress.c',
          'common\zstd_common.c', 'common\xxhash.c', 'decompress\huf_decompress.c', 'decompress\zstd_ddict.c',
          'decompress\zstd_decompress.c', 'decompress\zstd_decompress_block.c') |
        ForEach-Object { "`"$zstd\$_`"" }
# zstd: decoder only, no assembly (MSVC cannot build the .S file), no multithreading.
$zdef = '/DZSTD_DISABLE_ASM /DZSTD_MULTITHREAD=0 /DZSTD_LEGACY_SUPPORT=0'
$cmd = "cl /nologo /c /MT /Brepro /W3 $opt $zdef $($zsrc -join ' ') /Fo`"$obj\\`" && " +
       "cl /nologo /std:c++17 /W4 /WX /EHsc /MT /Brepro $opt $zdef `"$src\main.cpp`" `"$obj\*.obj`" " +
       "/Fo`"$obj\main.obj`" /Fe`"$exe`" /link /INCREMENTAL:NO /Brepro"
Remove-Item "$obj\*.obj" -ErrorAction SilentlyContinue
$log = Join-Path $obj 'build.log'
cmd /c "call `"$vcvars`" >nul && ($cmd) > `"$log`" 2>&1"
if ($LASTEXITCODE -ne 0) { Get-Content $log | Select-String -Pattern 'error|warning' | Select-Object -First 30; throw "build failed ($LASTEXITCODE), see $log" }

Copy-Item (Join-Path $src 'variant-map.txt') $obj -Force
$out = Get-Item $exe
'{0}  {1:N0} bytes  SHA-256 {2}' -f $out.FullName, $out.Length, (Get-FileHash $out.FullName).Hash
