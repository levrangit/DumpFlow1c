$ScriptVersion = 'v1.0.2'
$ScriptDate = '2026-10-03 00:53'
$ScriptName = 'manifest.ps1'
Write-Host "DumpFlow1c: $ScriptName — $ScriptVersion — $ScriptDate"

# DumpFlow1c: v1.0.1 — 2026-10-03 06:43
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DatabaseName
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configDir = Join-Path $root 'config'

$computer = $env:COMPUTERNAME
$terminalPath = Join-Path (Join-Path $configDir 'terminals') ($computer + '.json')
if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) {
    throw "Не найден файл терминала: $terminalPath"
}

$terminal = Get-Content -Raw -LiteralPath $terminalPath -Encoding UTF8 | ConvertFrom-Json
if ([string]$terminal.computer_name -ne $computer) {
    throw 'computer_name в terminal JSON не совпадает с COMPUTERNAME.'
}

$projectName = [string]$terminal.project_name
$mcpWork = [string]$terminal.mcp_work

if ([string]::IsNullOrWhiteSpace($projectName)) {
    throw 'В terminal JSON не задан project_name.'
}
if ($projectName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
    throw "Некорректный project_name: $projectName"
}
if ([string]::IsNullOrWhiteSpace($mcpWork)) {
    throw 'В terminal JSON не задан mcp_work.'
}
if (-not (Test-Path -LiteralPath $mcpWork -PathType Container)) {
    throw "Рабочий каталог не найден: $mcpWork"
}

$dbDir = Join-Path (Join-Path $configDir 'databases') $computer
if (-not (Test-Path -LiteralPath $dbDir -PathType Container)) {
    throw "Не найден каталог баз: $dbDir"
}

if ([string]::IsNullOrWhiteSpace($DatabaseName)) {
    $dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
}
else {
    if ($DatabaseName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw "Некорректный DatabaseName: $DatabaseName"
    }

    $dbFile = Join-Path $dbDir ($DatabaseName + '.json')
    if (-not (Test-Path -LiteralPath $dbFile -PathType Leaf)) {
        throw "Не найдена конфигурация базы: $dbFile"
    }

    $dbFiles = @(Get-Item -LiteralPath $dbFile)
}

if ($dbFiles.Count -eq 0) {
    throw "В каталоге нет JSON баз: $dbDir"
}

$snapshotId = (Get-Date).ToString('yyyyMMdd_HHmmss')
$dumpRoot = Join-Path (Join-Path $mcpWork 'dump') $projectName
$metadataRoot = Join-Path (Join-Path $mcpWork 'metadata') $projectName

New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null

function New-Manifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabaseName,

        [Parameter(Mandatory = $true)]
        [string]$DumpPath,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    if (-not (Test-Path -LiteralPath $DumpPath -PathType Container)) {
        throw "Не найден dump базы: $DumpPath"
    }

    $files = @(Get-ChildItem -LiteralPath $DumpPath -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)
    if ($files.Count -eq 0) {
        throw "Dump пуст: $DumpPath"
    }

    $started = Get-Date
    $fileRecords = New-Object System.Collections.Generic.List[object]
    $totalBytes = [int64]0
    $index = 0

    foreach ($file in $files) {
        $index++
        $relative = $file.FullName.Substring($DumpPath.Length).TrimStart('\','/')
        $relative = $relative.Replace('\','/')

        $record = [ordered]@{
            RelativePath = $relative
            SizeBytes    = [int64]$file.Length
            MD5          = (Get-FileHash -LiteralPath $file.FullName -Algorithm MD5 -ErrorAction Stop).Hash.ToUpperInvariant()
        }

        $fileRecords.Add([PSCustomObject]$record)
        $totalBytes += [int64]$file.Length

        if (($index -eq 1) -or ($index -eq $files.Count) -or (($index % 100) -eq 0)) {
            Write-Progress -Activity "Формирование manifest: $DatabaseName" -Status "$index/$($files.Count)" -PercentComplete ([int](($index * 100.0) / $files.Count))
        }
    }

    Write-Progress -Activity "Формирование manifest: $DatabaseName" -Completed

    $completed = Get-Date
    $manifest = [ordered]@{
        ManifestVersion = 1
        Project         = $projectName
        Database        = $DatabaseName
        SnapshotId      = $snapshotId
        CreatedAt       = $started.ToString('o')
        CompletedAt     = $completed.ToString('o')
        HashAlgorithm   = 'MD5'
        DumpPath        = "dump/$projectName/$DatabaseName"
        FileCount       = $files.Count
        TotalSizeBytes  = $totalBytes
        Files           = $fileRecords
    }

    $outputDirectory = Split-Path -Parent $OutputPath
    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

    Write-Host "MANIFEST: $OutputPath"
    Write-Host "Проект: $projectName"
    Write-Host "База: $DatabaseName"
    Write-Host "SnapshotId: $snapshotId"
    Write-Host ("Файлов: {0:N0}" -f $files.Count)
    Write-Host ("Размер: {0:N0} байт" -f $totalBytes)
}

Write-Host '------------------------------------------------------------'
Write-Host 'MCP - MANIFEST'
Write-Host '------------------------------------------------------------'
Write-Host "Компьютер: $computer"
Write-Host "Проект: $projectName"
Write-Host "Рабочий каталог: $mcpWork"
Write-Host "SnapshotId: $snapshotId"
Write-Host ("Баз к обработке: {0:N0}" -f $dbFiles.Count)
Write-Host ''

foreach ($dbFile in $dbFiles) {
    $db = Get-Content -Raw -LiteralPath $dbFile.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$db.db_source_id

    if ([string]::IsNullOrWhiteSpace($id)) {
        throw "В JSON не задан db_source_id: $($dbFile.FullName)"
    }
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw "Некорректный DB_SOURCE_ID: $id"
    }

    $dumpPath = Join-Path $dumpRoot $id
    $metadataDir = Join-Path $metadataRoot $id
    $manifestPath = Join-Path $metadataDir ("{0}_{1}_manifest.json" -f $id,$snapshotId)

    New-Manifest -DatabaseName $id -DumpPath $dumpPath -OutputPath $manifestPath
}

Write-Host ''
Write-Host 'MANIFEST завершён успешно.'
exit 0
