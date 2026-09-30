#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configDir = Join-Path $root 'config'

$common = Get-Content -Raw -LiteralPath (Join-Path $configDir 'common.json') -Encoding UTF8 | ConvertFrom-Json
$projectName = [string]$common.project_name
$rdpDrive = [string]$common.rdp_drive
$mcpPath = [string]$common.mcp_path
if ([string]::IsNullOrWhiteSpace($projectName)) { throw 'В common.json не задан project_name.' }
if ([string]::IsNullOrWhiteSpace($rdpDrive) -or [string]::IsNullOrWhiteSpace($mcpPath)) { throw 'В common.json не заданы rdp_drive/mcp_path.' }
if (-not (Test-Path -LiteralPath $rdpDrive)) { throw "RDP-диск недоступен: $rdpDrive" }

$rdpMcp = Join-Path $rdpDrive $mcpPath
$archiveDestination = Join-Path $rdpMcp 'archive'
$controlDestination = Join-Path $rdpMcp 'control_upload'
New-Item -ItemType Directory -Force -Path $archiveDestination,$controlDestination | Out-Null

$rclone = Join-Path (Join-Path $root 'tools') 'rclone.exe'
if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) { throw "Не найден rclone.exe: $rclone" }

$computer = $env:COMPUTERNAME
$terminalPath = Join-Path (Join-Path $configDir 'terminals') ($computer + '.json')
$terminal = Get-Content -Raw -LiteralPath $terminalPath -Encoding UTF8 | ConvertFrom-Json
$mcpWork = [string]$terminal.mcp_work
$metadataRoot = Join-Path (Join-Path $mcpWork 'metadata') $projectName
$archiveRoot = Join-Path $mcpWork 'archive'

if (-not (Test-Path -LiteralPath $metadataRoot -PathType Container)) { throw "Не найден metadata проекта: $metadataRoot" }
if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container)) { throw "Не найден archive: $archiveRoot" }

function Get-Md5([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToUpperInvariant()
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Invoke-RcloneCopyTo {
    param([string]$Source,[string]$Destination)
    Write-Host "Передача: $Source -> $Destination"
    & $rclone copyto $Source $Destination --progress --stats 5s --verbose
    if ($LASTEXITCODE -ne 0) { throw "rclone завершился с кодом $LASTEXITCODE: $Source" }
}

$dbDir = Join-Path (Join-Path $configDir 'databases') $computer
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
if ($dbFiles.Count -eq 0) { throw "В каталоге нет JSON баз: $dbDir" }

$transfers = New-Object System.Collections.Generic.List[object]

foreach ($dbFile in $dbFiles) {
    $db = Get-Content -Raw -LiteralPath $dbFile.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$db.db_source_id
    $metadataDir = Join-Path $metadataRoot $id

    $changesFiles = @(Get-ChildItem -LiteralPath $metadataDir -Filter ("changes_{0}_*.json" -f $id) -File | Sort-Object Name -Descending)
    if ($changesFiles.Count -eq 0) { throw "Не найден changes для $id" }

    $changesPath = $changesFiles[0].FullName
    $changes = Get-Content -Raw -LiteralPath $changesPath -Encoding UTF8 | ConvertFrom-Json
    $snapshotId = [string]$changes.SnapshotId
    if ([string]::IsNullOrWhiteSpace($snapshotId)) { throw "В changes отсутствует SnapshotId: $changesPath" }

    $manifestName = [string]$changes.CurrentManifest
    $manifestPath = Join-Path $metadataDir $manifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Не найден manifest: $manifestPath" }

    $archiveName = "{0}_{1}.7z" -f $id,$snapshotId
    $archivePath = Join-Path $archiveRoot $archiveName
    $shaName = $archiveName + '.sha256'
    $shaPath = Join-Path $archiveRoot $shaName

    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw "Не найден архив: $archivePath" }
    if (-not (Test-Path -LiteralPath $shaPath -PathType Leaf)) { throw "Не найден SHA256: $shaPath" }

    $manifestName = [IO.Path]::GetFileName($manifestPath)
    $changesName = [IO.Path]::GetFileName($changesPath)

    $transfers.Add([PSCustomObject]@{
        Project = $projectName
        Database = $id
        SnapshotId = $snapshotId
        Manifest = [PSCustomObject]@{
            Name = $manifestName
            SizeBytes = [int64](Get-Item -LiteralPath $manifestPath).Length
            MD5 = Get-Md5 $manifestPath
        }
        Changes = [PSCustomObject]@{
            Name = $changesName
            SizeBytes = [int64](Get-Item -LiteralPath $changesPath).Length
            MD5 = Get-Md5 $changesPath
        }
        Archive = [PSCustomObject]@{
            Name = $archiveName
            SizeBytes = [int64](Get-Item -LiteralPath $archivePath).Length
            SHA256 = Get-Sha256 $archivePath
        }
        ArchiveChecksum = [PSCustomObject]@{
            Name = $shaName
            SizeBytes = [int64](Get-Item -LiteralPath $shaPath).Length
        }
        LocalManifestPath = $manifestPath
        LocalChangesPath = $changesPath
        LocalArchivePath = $archivePath
        LocalShaPath = $shaPath
    })
}

$control = [ordered]@{
    ControlVersion = 1
    CreatedAt = (Get-Date).ToString('o')
    Project = $projectName
    SourceComputer = $computer
    Transfers = @(
        $transfers | ForEach-Object {
            [ordered]@{
                Project = $_.Project
                Database = $_.Database
                SnapshotId = $_.SnapshotId
                Manifest = $_.Manifest
                Changes = $_.Changes
                Archive = $_.Archive
                ArchiveChecksum = $_.ArchiveChecksum
            }
        }
    )
}

$controlPath = Join-Path $controlDestination 'control_upload.json'
$control | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $controlPath -Encoding UTF8

Write-Host ''
Write-Host '------------------------------------------------------------'
Write-Host 'MCP - UPLOAD'
Write-Host '------------------------------------------------------------'
Write-Host "Проект: $projectName"
Write-Host "Control upload: $controlPath"
Write-Host ("Баз: {0:N0}" -f $transfers.Count)
Write-Host ''

# Передаём ровно тот комплект, который описан control_upload.json.
foreach ($item in $transfers) {
    Invoke-RcloneCopyTo $item.LocalArchivePath (Join-Path $archiveDestination $item.Archive.Name)
    Invoke-RcloneCopyTo $item.LocalShaPath (Join-Path $archiveDestination $item.ArchiveChecksum.Name)
    Invoke-RcloneCopyTo $item.LocalManifestPath (Join-Path $archiveDestination $item.Manifest.Name)
    Invoke-RcloneCopyTo $item.LocalChangesPath (Join-Path $archiveDestination $item.Changes.Name)
}

# Независимо от control_upload.ps1 выполняем финальную проверку прямо с терминала.
# Это позволяет безопасно обновить state.json только после фактической доставки на RDP-диск.
foreach ($item in $transfers) {
    $remoteArchive = Join-Path $archiveDestination $item.Archive.Name
    $remoteSha = Join-Path $archiveDestination $item.ArchiveChecksum.Name
    $remoteManifest = Join-Path $archiveDestination $item.Manifest.Name
    $remoteChanges = Join-Path $archiveDestination $item.Changes.Name

    foreach ($pair in @(
        @($remoteArchive,[int64]$item.Archive.SizeBytes),
        @($remoteSha,[int64]$item.ArchiveChecksum.SizeBytes),
        @($remoteManifest,[int64]$item.Manifest.SizeBytes),
        @($remoteChanges,[int64]$item.Changes.SizeBytes)
    )) {
        if (-not (Test-Path -LiteralPath $pair[0] -PathType Leaf)) { throw "Файл не найден после передачи: $($pair[0])" }
        if ([int64](Get-Item -LiteralPath $pair[0]).Length -ne $pair[1]) { throw "Размер после передачи не совпадает: $($pair[0])" }
    }

    if ((Get-Sha256 $remoteArchive) -ne [string]$item.Archive.SHA256) { throw "SHA256 архива не совпадает: $remoteArchive" }
    if ((Get-Md5 $remoteManifest) -ne [string]$item.Manifest.MD5) { throw "MD5 manifest не совпадает: $remoteManifest" }
    if ((Get-Md5 $remoteChanges) -ne [string]$item.Changes.MD5) { throw "MD5 changes не совпадает: $remoteChanges" }

    $stateDir = Join-Path $metadataRoot $item.Database
    $statePath = Join-Path $stateDir 'state.json'
    $state = [ordered]@{
        Version = 1
        Project = $projectName
        Database = $item.Database
        LastSuccessfulSnapshotId = $item.SnapshotId
        LastSuccessfulManifest = $item.Manifest.Name
        LastSuccessfulChanges = $item.Changes.Name
        LastSuccessfulAt = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

    Write-Host "Доставка подтверждена: $($item.Database) / $($item.SnapshotId)"
}

Write-Host ''
Write-Host 'UPLOAD завершён успешно.'
Write-Host 'Комплект: .7z + .sha256 + manifest + changes'
Write-Host 'state.json обновлён только после проверки RDP-файлов.'
exit 0
