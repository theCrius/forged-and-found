# Writes the reverter's variant map (variant ItemId -> original ItemId) from the data
# mod's manifest export, <game>/shroudforge/exports/forged-and-found/manifest.json
# (written on every start while the mod is enabled). Variant ids are stable (derived from
# the pinned list), so the map only grows; regenerate it whenever variants are added.
# Usage: ./tools/make-variant-map.ps1 -Manifest <game>\shroudforge\exports\forged-and-found\manifest.json
param(
    [Parameter(Mandatory)][string]$Manifest,
    [string]$Out = (Join-Path $PSScriptRoot '..\native\variants-reverter\variant-map.txt')
)
$ErrorActionPreference = 'Stop'

$text = Get-Content -Raw -LiteralPath $Manifest
$rows = [regex]::Matches($text, '"originalId":(\d+),"index":(\d+),"name":"([^"]+)"[^}]*?"itemId":(\d+)')
if ($rows.Count -eq 0) { throw "no variants found in $Manifest" }
$lines = @('# variants-reverter variant map: <variant ItemId> <original ItemId> <variant debug name>',
           "# generated from the data mod's manifest export ($($rows.Count) variants); append-only like data/pinned.txt")
$seen = @{}
foreach ($r in $rows) {
    $variant = $r.Groups[4].Value
    if ($seen.ContainsKey($variant)) { throw "duplicate variant id $variant" }
    $seen[$variant] = 1
    $lines += '{0} {1} {2}' -f $variant, $r.Groups[1].Value, $r.Groups[3].Value
}
[IO.File]::WriteAllLines([IO.Path]::GetFullPath($Out), $lines)
'{0}: {1} variants' -f [IO.Path]::GetFullPath($Out), $rows.Count
