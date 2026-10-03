$ScriptVersion = 'v1.0.3'
$ScriptDate = '2026-10-03 13:30'
$ScriptName = 'upload.ps1'
Write-Host "DumpFlow1c: $ScriptName — $ScriptVersion — $ScriptDate"

#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configDir = Join-Path $root 'config'

$computer = $env:COMPUTERNAME
$terminalPath = Join-Path (Join-Path $configDir 'terminals') ($computer + '.json')
if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) { throw "Не найден файл терминала: $terminalPath" }
$terminal = Get-Content -Raw -LiteralPath $terminalPath -Encoding UTF8 | ConvertFrom-Json
if ([string]$terminal.computer_name -ne $computer) { throw 'computer_name в terminal JSON не совпадает с COMPUTERNAME.' }
$projectName = [string]$terminal.project_name
$rdpDrive = [string]$terminal.rdp_drive
$mcpPath = [string]$terminal.mcp_path
$mcpWork = [string]$terminal.mcp_work
if ([string]::IsNullOrWhiteSpace($projectName)) { throw 'В terminal JSON не задан project_name.' }
if ([string]::IsNullOrWhiteSpace($rdpDrive) -or [string]::IsNullOrWhiteSpace($mcpPath)) { throw 'В terminal JSON не заданы rdp_drive/mcp_path.' }
if ([string]::IsNullOrWhiteSpace($mcpWork)) { throw 'В terminal JSON не задан mcp_work.' }
if (-not (Test-Path -LiteralPath $rdpDrive)) { throw "RDP-диск недоступен: $rdpDrive" }

$rdpMcp = Join-Path $rdpDrive $mcpPath
$archiveDestination = Join-Path $rdpMcp 'archive'
$controlDestination = Join-Path $rdpMcp 'control_upload'
New-Item -ItemType Directory -Force -Path $archiveDestination,$controlDestination | Out-Null

$rclone = Join-Path (Join-Path $root 'tools') 'rclone.exe'
$rcloneConfig = Join-Path (Join-Path $root 'tools') 'rclone.conf'
if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) { throw "Не найден rclone.exe: $rclone" }

# Используем локальный конфиг рядом с rclone, чтобы rclone не искал
# пользовательский %APPDATA%\rclone\rclone.conf на каждом запуске.
if (-not (Test-Path -LiteralPath $rcloneConfig -PathType Leaf)) {
    Set-Content -LiteralPath $rcloneConfig -Value '' -Encoding ASCII
}

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

    $script:DiagNumber++
    $number = $script:DiagNumber
    $file = Get-Item -LiteralPath $Source
    $fileSize = [int64]$file.Length
    $before = Get-Date

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ("DIAGNOSTICS RCLONE #{0}" -f $number)
    Write-Host '============================================================'
    Write-Host ("Файл       : {0}" -f $file.Name)
    Write-Host ("Размер     : {0:N0} bytes" -f $fileSize)
    Write-Host ("До rclone  : {0}" -f $before.ToString('HH:mm:ss.fff'))

    if ($null -ne $script:DiagLastRcloneEnd) {
        $gapMs = ($before - $script:DiagLastRcloneEnd).TotalMilliseconds
        Write-Host ("Пауза между rclone: {0:N0} ms = {1:N3} sec = {2:N2} min" -f $gapMs, ($gapMs / 1000), ($gapMs / 60000))
    }
    else {
        Write-Host 'Пауза между rclone: первый запуск'
    }

    Write-Host ("Источник  : {0}" -f $Source)
    Write-Host ("Назначение: {0}" -f $Destination)
    Write-Host ''

    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $rclone --config $rcloneConfig copyto $Source $Destination --progress --stats 5s --verbose
    $exitCode = $LASTEXITCODE
    $timer.Stop()

    $after = Get-Date
    $script:DiagLastRcloneEnd = $after

    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host ("После rclone : {0}" -f $after.ToString('HH:mm:ss.fff'))
    Write-Host ("Время rclone : {0:N0} ms = {1:N3} sec" -f $timer.ElapsedMilliseconds, $timer.Elapsed.TotalSeconds)
    Write-Host ("Exit code    : {0}" -f $exitCode)
    Write-Host '------------------------------------------------------------'

    if ($exitCode -ne 0) { throw "rclone завершился с кодом ${exitCode}: $Source" }
}

$script:DiagLastRcloneEnd = $null`r`n$script:DiagNumber = 0`r`n`r`n$dbDir = Join-Path (Join-Path $configDir 'databases') $computer
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
if ($dbFiles.Count -eq 0) { throw "В каталоге нет JSON баз: $dbDir" }

$transfers = New-Object System.Collections.Generic.List[object]

foreach ($dbFile in $dbFiles) {
    $db = Get-Content -Raw -LiteralPath $dbFile.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$db.db_source_id
    $metadataDir = Join-Path $metadataRoot $id

    $changesFiles = @(Get-ChildItem -LiteralPath $metadataDir -Filter ("{0}_*_changes.json" -f $id) -File | Sort-Object Name -Descending)
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
$uploadTimer = [Diagnostics.Stopwatch]::StartNew()
foreach ($item in $transfers) {
    Invoke-RcloneCopyTo $item.LocalArchivePath (Join-Path $archiveDestination $item.Archive.Name)
    Invoke-RcloneCopyTo $item.LocalShaPath (Join-Path $archiveDestination $item.ArchiveChecksum.Name)
    Invoke-RcloneCopyTo $item.LocalManifestPath (Join-Path $archiveDestination $item.Manifest.Name)
    Invoke-RcloneCopyTo $item.LocalChangesPath (Join-Path $archiveDestination $item.Changes.Name)
}
$uploadTimer.Stop()
Write-Host ''
Write-Host '============================================================'
Write-Host ("DIAG ОБЩЕЕ ВРЕМЯ ПЕРЕДАЧИ: {0:N3} sec" -f $uploadTimer.Elapsed.TotalSeconds)
Write-Host '============================================================'
Write-Host ''

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
