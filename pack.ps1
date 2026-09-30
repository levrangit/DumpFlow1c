# DumpFlow1c: версия файла — 2026-10-01 01:45
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
$sevenZip = Join-Path (Join-Path $root 'tools') '7za.exe'

if (-not (Test-Path -LiteralPath $sevenZip -PathType Leaf)) { throw "Не найден 7za.exe: $sevenZip" }
New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ArchiveForDatabase {
    param([string]$DatabaseName)

    $metadataDir = Join-Path $metadataRoot $DatabaseName
    $changesFiles = @(Get-ChildItem -LiteralPath $metadataDir -Filter ("changes_{0}_*.json" -f $DatabaseName) -File | Sort-Object Name -Descending)
    if ($changesFiles.Count -eq 0) { throw "Не найден changes.json для $DatabaseName в $metadataDir" }

    $changesPath = $changesFiles[0].FullName
    $changes = Get-Content -Raw -LiteralPath $changesPath -Encoding UTF8 | ConvertFrom-Json
    $snapshotId = [string]$changes.SnapshotId
    if ([string]::IsNullOrWhiteSpace($snapshotId)) { throw "В changes отсутствует SnapshotId: $changesPath" }

    $manifestName = [string]$changes.CurrentManifest
    if ([string]::IsNullOrWhiteSpace($manifestName)) { throw "В changes отсутствует CurrentManifest: $changesPath" }
    $manifestPath = Join-Path $metadataDir $manifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Не найден manifest: $manifestPath" }

    $dumpPath = Join-Path $dumpRoot $DatabaseName
    if (-not (Test-Path -LiteralPath $dumpPath -PathType Container)) { throw "Не найден dump: $dumpPath" }

    $archivePath = Join-Path $archiveDir ("{0}_{1}.7z" -f $DatabaseName,$snapshotId)
    if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
    $listPath = Join-Path $archiveDir ('.files_' + [guid]::NewGuid().ToString('N') + '.txt')

    $transferFiles = @($changes.Files | Where-Object { $_.Action -in @('ADDED','MODIFIED') })
    foreach ($item in $transferFiles) {
        $relative = [string]$item.RelativePath
        $source = Join-Path $dumpPath ($relative -replace '/','\')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Файл из changes отсутствует в dump: $relative"
        }
    }

    try {
        $sevenZipStdout = Join-Path $archiveDir ('.7za_stdout_' + [guid]::NewGuid().ToString('N') + '.tmp')
        $sevenZipStderr = Join-Path $archiveDir ('.7za_stderr_' + [guid]::NewGuid().ToString('N') + '.tmp')

        if ($transferFiles.Count -gt 0) {
            $lines = @($transferFiles | ForEach-Object { [string]$_.RelativePath })
            $lines | Set-Content -LiteralPath $listPath -Encoding UTF8

            Push-Location $dumpPath
            try {
                & $sevenZip a -t7z -mx=5 -mmt=on -bsp0 -bso0 $archivePath ("@" + $listPath) -scsUTF-8 > $sevenZipStdout 2> $sevenZipStderr
                $rc = $LASTEXITCODE
            }
            finally {
                Pop-Location
            }
            if ($rc -ne 0) {
                $details = @()
                if (Test-Path -LiteralPath $sevenZipStdout) { $details += Get-Content -LiteralPath $sevenZipStdout -Raw }
                if (Test-Path -LiteralPath $sevenZipStderr) { $details += Get-Content -LiteralPath $sevenZipStderr -Raw }
                $details = (($details -join [Environment]::NewLine).Trim())
                if ([string]::IsNullOrWhiteSpace($details)) { $details = '7-Zip не вернул текст ошибки.' }
                throw ("7za завершился с кодом {0} для {1}: {2}" -f $rc, $DatabaseName, $details)
            }
        }
        else {
            # Создаём корректный пустой 7z: временно добавляем маркер и сразу удаляем его из архива.
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

        # В archive лежит полный транспортный комплект версии.
        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $archiveDir $manifestName) -Force
        Copy-Item -LiteralPath $changesPath -Destination (Join-Path $archiveDir ([IO.Path]::GetFileName($changesPath))) -Force

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
        if (Test-Path -LiteralPath $listPath) { Remove-Item -LiteralPath $listPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $sevenZipStdout) { Remove-Item -LiteralPath $sevenZipStdout -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $sevenZipStderr) { Remove-Item -LiteralPath $sevenZipStderr -Force -ErrorAction SilentlyContinue }
    }
}

$dbDir = Join-Path (Join-Path $configDir 'databases') $computer
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
if ($dbFiles.Count -eq 0) { throw "В каталоге нет JSON баз: $dbDir" }

$results = New-Object System.Collections.Generic.List[object]
foreach ($dbFile in $dbFiles) {
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
