# Pinned compiler for every build script in native/ (dot-source it: . "$PSScriptRoot\msvc.ps1").
# The same source built by another MSVC version gives a different binary, and only a DLL someone has
# run in game should ship. GitHub's runner and every local build use exactly this toolset; a machine
# without it gets an error, never a silent build with another compiler.
# Any Visual Studio installation may provide it: Visual Studio 2022 17.14 as its own toolset, or a
# newer Visual Studio with the side-by-side component "MSVC v143 - VS 2022 C++ x64/x86 build tools
# (v14.44-17.14)".
$Toolset = '14.44.35207'

# Returns the vcvars64.bat of an installation that has the pinned toolset. Call it as
#   cmd /c "call `"$vcvars`" -vcvars_ver=$Toolset >nul && ..."
function Get-PinnedVcvars {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw 'Visual Studio Installer not found: install Visual Studio 2022 Build Tools 17.14 (see README, Building from source)' }
    $installs = @(& $vswhere -products * -sort -property installationPath)
    $vs = $installs | Where-Object { Test-Path (Join-Path $_ "VC\Tools\MSVC\$Toolset\bin\Hostx64\x64\cl.exe") } | Select-Object -First 1
    if (-not $vs) {
        $found = foreach ($i in $installs) { Get-ChildItem (Join-Path $i 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) in $i" } }
        throw "MSVC toolset $Toolset not found in any Visual Studio installation (found: $(if ($found) { $found -join '; ' } else { 'none' })). " +
              "Install Visual Studio 2022 17.14 Build Tools, or add the individual component " +
              "'MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.44-17.14)' (see README, Building from source)"
    }
    $env:PATH = "$(Split-Path $vswhere);$env:PATH"  # vcvars64.bat calls vswhere by name
    Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
}

# The linker writes its version into the PE header: check that the pin held.
function Assert-PinnedLinker([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    $linker = '{0}.{1}' -f $bytes[$pe + 26], $bytes[$pe + 27]
    if (-not $Toolset.StartsWith("$linker.")) { throw "$path linked by MSVC $linker, expected $Toolset" }
}
