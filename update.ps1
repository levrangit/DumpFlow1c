#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Write-Host '============================================================'
Write-Host 'MCP - UPDATE'
Write-Host '============================================================'

& (Join-Path $root 'prepare.ps1')
if ($LASTEXITCODE -ne 0) { throw "prepare.ps1 завершился с кодом $LASTEXITCODE." }

& (Join-Path $root 'dump_config.ps1')
if ($LASTEXITCODE -ne 0) { throw "dump_config.ps1 завершился с кодом $LASTEXITCODE." }

$common = Get-Content -Raw -LiteralPath (Join-Path $root 'config\common.json') -Encoding UTF8 | ConvertFrom-Json
$projectName = [string]$common.project_name
$computer = $env:COMPUTERNAME
$terminal = Get-Content -Raw -LiteralPath (Join-Path $root ("config\terminals\{0}.json" -f $computer)) -Encoding UTF8 | ConvertFrom-Json
$mcpWork = [string]$terminal.mcp_work
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
    $manifestName = "manifest_{0}_{1}.json" -f $id,$snapshotId
    $changesName = "changes_{0}_{1}.json" -f $id,$snapshotId
    $manifestPath = Join-Path $metadataDir $manifestName
    $changesPath = Join-Path $metadataDir $changesName
    $statePath = Join-Path $metadataDir 'state.json'

    & (Join-Path $root 'manifest.ps1') -Path $dumpPath -ProjectName $projectName -DatabaseName $id -SnapshotId $snapshotId -OutputPath $manifestPath -WithMD5
    if ($LASTEXITCODE -ne 0) { throw "manifest.ps1 завершился с кодом $LASTEXITCODE для $id." }

    & (Join-Path $root 'compare_manifests.ps1') -CurrentManifestPath $manifestPath -StatePath $statePath -OutputPath $changesPath
    if ($LASTEXITCODE -ne 0) { throw "compare_manifests.ps1 завершился с кодом $LASTEXITCODE для $id." }
}

& (Join-Path $root 'pack.ps1')
if ($LASTEXITCODE -ne 0) { throw "pack.ps1 завершился с кодом $LASTEXITCODE." }

& (Join-Path $root 'upload.ps1')
if ($LASTEXITCODE -ne 0) { throw "upload.ps1 завершился с кодом $LASTEXITCODE." }

Write-Host ''
Write-Host '============================================================'
Write-Host 'MCP UPDATE COMPLETED'
Write-Host '============================================================'
exit 0
