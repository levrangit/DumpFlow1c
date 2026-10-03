$ScriptVersion = 'v1.0.2'
$ScriptDate = '2026-10-03 00:53'
$ScriptName = 'pack.ps1'
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
$mcpWork = [string]$terminal.mcp_work
if ([string]::IsNullOrWhiteSpace($projectName)) { throw 'В terminal JSON не задан project_name.' }
if ([string]::IsNullOrWhiteSpace($mcpWork)) { throw 'В terminal JSON не задан mcp_work.' }

$dumpRoot = Join-Path (Join-Path $mcpWork 'dump') $projectName
$metadataRoot = Join-Path (Join-Path $mcpWork 'metadata') $projectName
$archiveDir = Join-Path $mcpWork 'archive'

$sevenZipSource = Join-Path (Join-Path $root 'tools') '7za.exe'
$localToolsDir = Join-Path $mcpWork 'tools'
$sevenZip = Join-Path $localToolsDir '7za.exe'

function Write-Step([string]$Text) {
    Write-Host ("[PACK] {0}" -f $Text)
}

New-Item -ItemType Directory -Force -Path $localToolsDir | Out-Null
if (-not (Test-Path -LiteralPath $sevenZipSource -PathType Leaf)) { throw "Не найден исходный 7za.exe: $sevenZipSource" }

Write-Host ''
Write-Host '============================================================'
Write-Host 'СТАРТ АРХИВАЦИИ'
Write-Host '============================================================'
Write-Step ("Терминал: {0}" -f $computer)
Write-Step ("Проект: {0}" -f $projectName)
Write-Step ("Рабочий каталог MCP: {0}" -f $mcpWork)
Write-Step ("Каталог dump: {0}" -f $dumpRoot)
Write-Step ("Каталог archive: {0}" -f $archiveDir)
Write-Step ("Источник 7-Zip: {0}" -f $sevenZipSource)
Write-Step ("Локальный 7-Zip: {0}" -f $sevenZip)

Write-Step 'Копирую 7-Zip с RDP-диска в локальный каталог MCP.'
Copy-Item -LiteralPath $sevenZipSource -Destination $sevenZip -Force
if (-not (Test-Path -LiteralPath $sevenZip -PathType Leaf)) { throw "Не удалось скопировать 7za.exe: $sevenZip" }
Write-Step '7-Zip скопирован локально.'

New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ArchiveForDatabase {
    param([string]$DatabaseName)

    $metadataDir = Join-Path $metadataRoot $DatabaseName
    $changesFiles = @(Get-ChildItem -LiteralPath $metadataDir -Filter ("{0}_*_changes.json" -f $DatabaseName) -File | Sort-Object Name -Descending)
    if ($changesFiles.Count -eq 0) { throw "Не найден changes.json для $DatabaseName в $metadataDir" }

    Write-Step ("База {0}: найден последний changes-файл." -f $DatabaseName)
    $changesPath = $changesFiles[0].FullName
    Write-Step ("База {0}: читаю changes: {1}" -f $DatabaseName, $changesFiles[0].Name)
    $changes = Get-Content -Raw -LiteralPath $changesPath -Encoding UTF8 | ConvertFrom-Json
    $snapshotId = [string]$changes.SnapshotId
    if ([string]::IsNullOrWhiteSpace($snapshotId)) { throw "В changes отсутствует SnapshotId: $changesPath" }

    $manifestName = [string]$changes.CurrentManifest
    if ([string]::IsNullOrWhiteSpace($manifestName)) { throw "В changes отсутствует CurrentManifest: $changesPath" }
    Write-Step ("База {0}: SnapshotId = {1}" -f $DatabaseName, $snapshotId)
    $manifestPath = Join-Path $metadataDir $manifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Не найден manifest: $manifestPath" }

    Write-Step ("База {0}: проверяю manifest и dump." -f $DatabaseName)
    $dumpPath = Join-Path $dumpRoot $DatabaseName
    if (-not (Test-Path -LiteralPath $dumpPath -PathType Container)) { throw "Не найден dump: $dumpPath" }

    $archivePath = Join-Path $archiveDir ("{0}_{1}.7z" -f $DatabaseName,$snapshotId)
    if (Test-Path -LiteralPath $archivePath) {
        Write-Step ("База {0}: удаляю существующий архив перед пересозданием: {1}" -f $DatabaseName, $archivePath)
        Remove-Item -LiteralPath $archivePath -Force
    }
    $listPath = Join-Path $archiveDir ('.files_' + [guid]::NewGuid().ToString('N') + '.txt')

    $transferFiles = @($changes.Files | Where-Object { $_.Action -in @('ADDED','MODIFIED') })
    Write-Step ("База {0}: к упаковке файлов = {1}; удалённых файлов = {2}." -f $DatabaseName, $transferFiles.Count, [int]$changes.DeletedCount)
    Write-Step ("База {0}: проверяю наличие всех файлов в текущем dump." -f $DatabaseName)
    foreach ($item in $transferFiles) {
        $relative = [string]$item.RelativePath
        $source = Join-Path $dumpPath ($relative -replace '/','\')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Файл из changes отсутствует в dump: $relative"
        }
    }

    try {
        Write-Step ("База {0}: подготовка временных файлов и списка архивации." -f $DatabaseName)

        if ($transferFiles.Count -gt 0) {
            $lines = @($transferFiles | ForEach-Object { [string]$_.RelativePath })
            $lines | Set-Content -LiteralPath $listPath -Encoding UTF8
            Write-Step ("База {0}: список файлов создан." -f $DatabaseName)
            Write-Step ("База {0}: запускаю локальный 7-Zip, далее будет отображаться прогресс." -f $DatabaseName)

            Push-Location $dumpPath
            try {
                $argumentList = @(
                    'a',
                    '-t7z',
                    '-mx=5',
                    '-mmt=on',
                    '-bsp1',
                    '-bso1',
                    $archivePath,
                    ('@' + $listPath),
                    '-scsUTF-8'
                )

                # Запускаем 7-Zip напрямую, без cmd.exe и перенаправления stdout/stderr.
                # -bsp1 выводит прогресс в одну строку с возвратом каретки.
                & $sevenZip @argumentList
                $rc = $LASTEXITCODE
            }
            finally {
                Pop-Location
            }

            if ($rc -ne 0) {
                throw ("7za завершился с кодом {0} для {1}. Вывод 7-Zip приведён выше." -f $rc, $DatabaseName)
            }
        }
        else {
            Write-Step ("База {0}: изменений для упаковки нет, создаю корректный пустой 7z." -f $DatabaseName)
            $sevenZipStdout = Join-Path $archiveDir ('.7za_stdout_' + [guid]::NewGuid().ToString('N') + '.txt')
            $sevenZipStderr = Join-Path $archiveDir ('.7za_stderr_' + [guid]::NewGuid().ToString('N') + '.txt')
            $emptyMarker = Join-Path $archiveDir ('.empty_' + [guid]::NewGuid().ToString('N') + '.txt')
            Set-Content -LiteralPath $emptyMarker -Value 'empty' -Encoding ASCII
            & $sevenZip a -t7z -mx=5 -mmt=on -bsp0 -bso0 $archivePath $emptyMarker > $sevenZipStdout 2> $sevenZipStderr
            $rc = $LASTEXITCODE
            if ($rc -ne 0) {
                $details = @()
                if (Test-Path -LiteralPath $sevenZipStdout) { $details += Get-Content -LiteralPath $sevenZipStdout -Raw }
                if (Test-Path -LiteralPath $sevenZipStderr) { $details += Get-Content -LiteralPath $sevenZipStderr -Raw }
                $details = (($details -join [Environment]::NewLine).Trim())
                if ([string]::IsNullOrWhiteSpace($details)) { $details = '7-Zip не вернул текст ошибки.' }
                throw ("Не удалось создать пустой архив для {0}: {1}" -f $DatabaseName, $details)
            }

            $markerName = [IO.Path]::GetFileName($emptyMarker)
            & $sevenZip d $archivePath $markerName -bsp0 -bso0 > $sevenZipStdout 2> $sevenZipStderr
            $rc = $LASTEXITCODE
            Remove-Item -LiteralPath $emptyMarker -Force -ErrorAction SilentlyContinue
            if ($rc -ne 0) {
                $details = @()
                if (Test-Path -LiteralPath $sevenZipStdout) { $details += Get-Content -LiteralPath $sevenZipStdout -Raw }
                if (Test-Path -LiteralPath $sevenZipStderr) { $details += Get-Content -LiteralPath $sevenZipStderr -Raw }
                $details = (($details -join [Environment]::NewLine).Trim())
                if ([string]::IsNullOrWhiteSpace($details)) { $details = '7-Zip не вернул текст ошибки.' }
                throw ("Не удалось удалить маркер из пустого архива {0}: {1}" -f $DatabaseName, $details)
            }
        }

        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw "Архив не создан: $archivePath" }

        Write-Step ("База {0}: архив создан, рассчитываю SHA-256." -f $DatabaseName)
        $sha256 = Get-Hash $archivePath
        $shaPath = $archivePath + '.sha256'
        ($sha256 + '  ' + [IO.Path]::GetFileName($archivePath)) | Set-Content -LiteralPath $shaPath -Encoding ASCII

        $archiveSize = (Get-Item -LiteralPath $archivePath).Length
        $archiveInfo = Get-Item -LiteralPath $archivePath
        Write-Host "Архив: $archivePath"
        Write-Host ("Изменённых файлов: {0:N0}" -f $transferFiles.Count)
        Write-Host ("Удалённых файлов: {0:N0}" -f [int]$changes.DeletedCount)
        Write-Host ("Размер: {0:N0} байт" -f $archiveSize)
        Write-Host "SHA-256: $sha256"

        Write-Step ("База {0}: копирую manifest и changes в archive." -f $DatabaseName)
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $archiveDir $manifestName) -Force
        Copy-Item -LiteralPath $changesPath -Destination (Join-Path $archiveDir ([IO.Path]::GetFileName($changesPath))) -Force

        Write-Step ("База {0}: упаковка завершена успешно." -f $DatabaseName)
        return [PSCustomObject]@{
            Database = $DatabaseName
            SnapshotId = $snapshotId
            ArchivePath = $archivePath
            ShaPath = $shaPath
            ManifestPath = Join-Path $archiveDir $manifestName
            ChangesPath = Join-Path $archiveDir ([IO.Path]::GetFileName($changesPath))
            ArchiveSizeBytes = [int64]$archiveInfo.Length
            ArchiveSha256 = $sha256
        }
    }
    finally {
        if ($listPath -and (Test-Path -LiteralPath $listPath)) { Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue }
        if ($sevenZipStdout -and (Test-Path -LiteralPath $sevenZipStdout)) { Remove-Item -LiteralPath $sevenZipStdout -Force -ErrorAction SilentlyContinue }
        if ($sevenZipStderr -and (Test-Path -LiteralPath $sevenZipStderr)) { Remove-Item -LiteralPath $sevenZipStderr -Force -ErrorAction SilentlyContinue }
    }
}

$dbDir = Join-Path (Join-Path $configDir 'databases') $computer
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
if ($dbFiles.Count -eq 0) { throw "В каталоге нет JSON баз: $dbDir" }

$results = New-Object System.Collections.Generic.List[object]
Write-Step ("Найдено баз для архивации: {0}" -f $dbFiles.Count)
foreach ($dbFile in $dbFiles) {
    Write-Step ("Переходим к базе из конфигурации: {0}" -f $dbFile.Name)
    $db = Get-Content -Raw -LiteralPath $dbFile.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$db.db_source_id
    $results.Add((Get-ArchiveForDatabase -DatabaseName $id))
}

Write-Host ''
Write-Host '============================================================'
Write-Host 'PACK завершён успешно.'
Write-Host '============================================================'
Write-Host ("Баз: {0:N0}" -f $results.Count)
exit 0
