$ScriptVersion = 'v1.0.2'
$ScriptDate = '2026-10-03 00:53'
$ScriptName = 'update.ps1'
Write-Host "DumpFlow1c: $ScriptName — $ScriptVersion — $ScriptDate"

# DumpFlow1c: v1.0.1 — 2026-10-03 06:43
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$skipPrepare = $false
$skipDumpConfig = $false
$skipManifest = $false
$skipCompareManifests = $false
$skipPack = $false
$skipUpload = $false

foreach ($argument in $args) {
    switch ($argument) {
        '--NoPrepare'             { $skipPrepare = $true; continue }
        '--NoDump_config'        { $skipDumpConfig = $true; continue }
        '--NoManifest'           { $skipManifest = $true; continue }
        '--NoCompare_manifests'  { $skipCompareManifests = $true; continue }
        '--NoPack'               { $skipPack = $true; continue }
        '--NoUpload'             { $skipUpload = $true; continue }
        default { throw "Неизвестный флаг update.ps1: $argument" }
    }
}

Write-Host '============================================================'
Write-Host 'MCP - UPDATE'
Write-Host '============================================================'

if (-not $skipPrepare) {
    Write-Host 'Запуск prepare.ps1...'
    & (Join-Path $root 'prepare.ps1')
    if ($LASTEXITCODE -ne 0) { throw "prepare.ps1 завершился с кодом $LASTEXITCODE." }
} else {
    Write-Host 'Пропуск prepare.ps1 (--NoPrepare).'
}

if (-not $skipDumpConfig) {
    Write-Host 'Запуск dump_config.ps1...'
    & (Join-Path $root 'dump_config.ps1')
    if ($LASTEXITCODE -ne 0) { throw "dump_config.ps1 завершился с кодом $LASTEXITCODE." }
} else {
    Write-Host 'Пропуск dump_config.ps1 (--NoDump_config).'
}

$computer = $env:COMPUTERNAME
$terminalPath = Join-Path $root ("config\terminals\{0}.json" -f $computer)
if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) { throw "Не найден файл терминала: $terminalPath" }
$terminal = Get-Content -Raw -LiteralPath $terminalPath -Encoding UTF8 | ConvertFrom-Json
$projectName = [string]$terminal.project_name
$mcpWork = [string]$terminal.mcp_work
if ([string]::IsNullOrWhiteSpace($projectName)) { throw 'В terminal JSON не задан project_name.' }
if ([string]::IsNullOrWhiteSpace($mcpWork)) { throw 'В terminal JSON не задан mcp_work.' }
$dumpRoot = Join-Path (Join-Path $mcpWork 'dump') $projectName
$metadataRoot = Join-Path (Join-Path $mcpWork 'metadata') $projectName
New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null

$dbDir = Join-Path $root ("config\databases\{0}" -f $computer)
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
if ($dbFiles.Count -eq 0) { throw "Не найдено JSON баз: $dbDir" }

foreach ($dbFile in $dbFiles) {
    $db = Get-Content -Raw -LiteralPath $dbFile.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$db.db_source_id
    $dumpPath = Join-Path $dumpRoot $id
    $metadataDir = Join-Path $metadataRoot $id
    New-Item -ItemType Directory -Force -Path $metadataDir | Out-Null

    $snapshotId = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $manifestName = "{0}_{1}_manifest.json" -f $id,$snapshotId
    $changesName = "{0}_{1}_changes.json" -f $id,$snapshotId
    $manifestPath = Join-Path $metadataDir $manifestName
    $changesPath = Join-Path $metadataDir $changesName
    $statePath = Join-Path $metadataDir 'state.json'

    if (-not $skipManifest) {
        & (Join-Path $root 'manifest.ps1') -Path $dumpPath -ProjectName $projectName -DatabaseName $id -SnapshotId $snapshotId -OutputPath $manifestPath -WithMD5
        if ($LASTEXITCODE -ne 0) { throw "manifest.ps1 завершился с кодом $LASTEXITCODE для $id." }
    } else {
        Write-Host "Пропуск manifest.ps1 для $id (--NoManifest)."
    }

    if (-not $skipCompareManifests) {
        & (Join-Path $root 'compare_manifests.ps1') -CurrentManifestPath $manifestPath -StatePath $statePath -OutputPath $changesPath
        if ($LASTEXITCODE -ne 0) { throw "compare_manifests.ps1 завершился с кодом $LASTEXITCODE для $id." }
    } else {
        Write-Host "Пропуск compare_manifests.ps1 для $id (--NoCompare_manifests)."
    }
}

if (-not $skipPack) {
    Write-Host 'Запуск pack.ps1...'
    & (Join-Path $root 'pack.ps1')
    if ($LASTEXITCODE -ne 0) { throw "pack.ps1 завершился с кодом $LASTEXITCODE." }
} else {
    Write-Host 'Пропуск pack.ps1 (--NoPack).'
}

if (-not $skipUpload) {
    Write-Host 'Запуск upload.ps1...'
    & (Join-Path $root 'upload.ps1')
    if ($LASTEXITCODE -ne 0) { throw "upload.ps1 завершился с кодом $LASTEXITCODE." }
} else {
    Write-Host 'Пропуск upload.ps1 (--NoUpload).'
}

Write-Host ''
Write-Host '============================================================'
Write-Host 'MCP UPDATE COMPLETED'
Write-Host '============================================================'
exit 0
