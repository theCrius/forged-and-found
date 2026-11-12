# Builds variants-reverter.exe (offline save converter) with the MSVC Build Tools.
# zstd's decoder is compiled in from native/third_party/zstd (BSD); /MT links the CRT
# statically, so the exe runs without a Visual C++ runtime.
# Usage: ./native/build-reverter.ps1 [-Config Release|Debug]
param([ValidateSet('Release', 'Debug')][string]$Config = 'Release')
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'msvc.ps1')  # pinned MSVC toolset
$vcvars = Get-PinnedVcvars

$src = Join-Path $PSScriptRoot 'variants-reverter'
$zstd = Join-Path $PSScriptRoot 'third_party\zstd'
$obj = Join-Path $PSScriptRoot "build\reverter-$Config"
New-Item -ItemType Directory -Force -Path $obj | Out-Null
$exe = Join-Path $obj 'variants-reverter.exe'

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
cmd /c "call `"$vcvars`" -vcvars_ver=$Toolset >nul && ($cmd) > `"$log`" 2>&1"
if ($LASTEXITCODE -ne 0) { Get-Content $log | Select-String -Pattern 'error|warning' | Select-Object -First 30; throw "build failed ($LASTEXITCODE), see $log" }
Assert-PinnedLinker $exe

Copy-Item (Join-Path $src 'variant-map.txt') $obj -Force
$out = Get-Item $exe
'{0}  {1:N0} bytes  SHA-256 {2}  (MSVC {3})' -f $out.FullName, $out.Length, (Get-FileHash $out.FullName).Hash, $Toolset
