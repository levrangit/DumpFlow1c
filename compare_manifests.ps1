# DumpFlow1c: версия файла — 2026-09-30 22:00
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CurrentManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
}

$current = Read-Json $CurrentManifestPath
if ($null -eq $current) { throw "Не найден текущий manifest: $CurrentManifestPath" }

$previous = $null
$previousManifestPath = $null
$state = Read-Json $StatePath

if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.LastSuccessfulManifest)) {
    $candidate = Join-Path (Split-Path -Parent $StatePath) ([string]$state.LastSuccessfulManifest)
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $previousManifestPath = $candidate
        $previous = Read-Json $candidate
    }
}

$old = @{}
if ($null -ne $previous) {
    foreach ($item in @($previous.Files)) {
        $old[[string]$item.RelativePath] = $item
    }
}

$new = @{}
foreach ($item in @($current.Files)) {
    $new[[string]$item.RelativePath] = $item
}

$changes = New-Object System.Collections.Generic.List[object]
$added = 0
$modified = 0
$deleted = 0
$unchanged = 0

foreach ($path in ($new.Keys | Sort-Object)) {
    $item = $new[$path]
    if (-not $old.ContainsKey($path)) {
        $changes.Add([PSCustomObject][ordered]@{
            RelativePath = $path
            Action       = 'ADDED'
            SizeBytes    = [int64]$item.SizeBytes
            MD5          = [string]$item.MD5
        })
        $added++
    }
    elseif ([string]$old[$path].MD5 -ne [string]$item.MD5 -or [int64]$old[$path].SizeBytes -ne [int64]$item.SizeBytes) {
        $changes.Add([PSCustomObject][ordered]@{
            RelativePath  = $path
            Action        = 'MODIFIED'
            SizeBytes     = [int64]$item.SizeBytes
            MD5           = [string]$item.MD5
            PreviousMD5   = [string]$old[$path].MD5
        })
        $modified++
    }
    else {
        $unchanged++
    }
}

foreach ($path in ($old.Keys | Sort-Object)) {
    if (-not $new.ContainsKey($path)) {
        $item = $old[$path]
        $changes.Add([PSCustomObject][ordered]@{
            RelativePath      = $path
            Action            = 'DELETED'
            PreviousSizeBytes = [int64]$item.SizeBytes
            PreviousMD5       = [string]$item.MD5
        })
        $deleted++
    }
}

$result = [ordered]@{
    ChangesVersion       = 1
    Project              = [string]$current.Project
    Database             = [string]$current.Database
    SnapshotId           = [string]$current.SnapshotId
    CreatedAt            = (Get-Date).ToString('o')
    PreviousSnapshotId   = if ($null -ne $previous) { [string]$previous.SnapshotId } else { $null }
    PreviousManifest     = if ($null -ne $previousManifestPath) { [IO.Path]::GetFileName($previousManifestPath) } else { $null }
    CurrentManifest      = [IO.Path]::GetFileName($CurrentManifestPath)
    HashAlgorithm        = 'MD5'
    AddedCount           = $added
    ModifiedCount        = $modified
    DeletedCount         = $deleted
    UnchangedCount       = $unchanged
    TransferFileCount    = $added + $modified
    Files                = $changes
}

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host "CHANGES: $OutputPath"
Write-Host "Project: $($result.Project)"
Write-Host "Database: $($result.Database)"
Write-Host "SnapshotId: $($result.SnapshotId)"
Write-Host ("ADDED: {0}; MODIFIED: {1}; DELETED: {2}; UNCHANGED: {3}" -f $added,$modified,$deleted,$unchanged)
exit 0
