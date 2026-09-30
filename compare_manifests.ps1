# DumpFlow1c: версия файла — 2026-10-01 00:03
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

$metadataRoot = Join-Path (Join-Path $mcpWork 'metadata') $projectName

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
}

function Compare-Database {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabaseName
    )

    $metadataDir = Join-Path $metadataRoot $DatabaseName
    if (-not (Test-Path -LiteralPath $metadataDir -PathType Container)) {
        throw "Не найден metadata-каталог базы: $metadataDir"
    }

    $manifestFiles = @(Get-ChildItem -LiteralPath $metadataDir -Filter ("manifest_{0}_*.json" -f $DatabaseName) -File | Sort-Object Name -Descending)
    if ($manifestFiles.Count -eq 0) {
        throw "Не найден manifest для $DatabaseName в $metadataDir"
    }

    $currentManifestPath = $manifestFiles[0].FullName
    $current = Read-Json $currentManifestPath
    if ($null -eq $current) {
        throw "Не удалось прочитать текущий manifest: $currentManifestPath"
    }

    $statePath = Join-Path $metadataDir 'state.json'
    $state = Read-Json $statePath

    $previous = $null
    $previousManifestPath = $null

    if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace([string]$state.LastSuccessfulManifest)) {
        $candidate = Join-Path $metadataDir ([string]$state.LastSuccessfulManifest)
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
        elseif (
            [string]$old[$path].MD5 -ne [string]$item.MD5 -or
            [int64]$old[$path].SizeBytes -ne [int64]$item.SizeBytes
        ) {
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
        CurrentManifest      = [IO.Path]::GetFileName($currentManifestPath)
        HashAlgorithm        = 'MD5'
        AddedCount           = $added
        ModifiedCount        = $modified
        DeletedCount         = $deleted
        UnchangedCount       = $unchanged
        TransferFileCount    = $added + $modified
        Files                = $changes
    }

    $changesPath = Join-Path $metadataDir ("changes_{0}_{1}.json" -f $DatabaseName,$current.SnapshotId)
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $changesPath -Encoding UTF8

    Write-Host "CHANGES: $changesPath"
    Write-Host "Project: $($result.Project)"
    Write-Host "Database: $($result.Database)"
    Write-Host "SnapshotId: $($result.SnapshotId)"
    Write-Host ("ADDED: {0}; MODIFIED: {1}; DELETED: {2}; UNCHANGED: {3}" -f $added,$modified,$deleted,$unchanged)
}

Write-Host '------------------------------------------------------------'
Write-Host 'MCP - COMPARE MANIFESTS'
Write-Host '------------------------------------------------------------'
Write-Host "Компьютер: $computer"
Write-Host "Проект: $projectName"
Write-Host "Рабочий каталог: $mcpWork"
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

    Compare-Database -DatabaseName $id
}

Write-Host ''
Write-Host 'COMPARE MANIFESTS завершён успешно.'
exit 0
