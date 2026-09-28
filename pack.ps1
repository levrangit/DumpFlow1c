#Requires -Version 5.1
# Если PowerShell запрещает запуск скрипта, выполните:
# Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
# Проверить текущую политику:
# Get-ExecutionPolicy -List

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configDir = Join-Path $root 'config'
$computer = $env:COMPUTERNAME

Write-Host "------------------------------------------------------------"
Write-Host "MCP - PACK"
Write-Host "------------------------------------------------------------"

$terminalPath = Join-Path (Join-Path $configDir 'terminals') ($computer + '.json')
if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) { throw "Не найден файл терминала: $terminalPath" }

$terminal = Get-Content -Raw -LiteralPath $terminalPath -Encoding UTF8 | ConvertFrom-Json
$mcpWork = [string]$terminal.mcp_work
if ([string]::IsNullOrWhiteSpace($mcpWork)) {
    throw "В конфигурации терминала не указан mcp_work: $terminalPath"
}

$sourceSevenZip = Join-Path (Join-Path $root 'tools') '7za.exe'
if (-not (Test-Path -LiteralPath $sourceSevenZip -PathType Leaf)) {
    throw "Не найден исходный 7za.exe: $sourceSevenZip"
}

# Локальный 7za.exe. Он остается после завершения упаковки.
$localToolsDir = Join-Path $mcpWork 'tools'
$localSevenZip = Join-Path $localToolsDir '7za.exe'
New-Item -ItemType Directory -Force -Path $localToolsDir | Out-Null

Write-Host ""
Write-Host "Копирование 7za.exe на локальный диск:"
Write-Host "  FROM: $sourceSevenZip"
Write-Host "  TO:   $localSevenZip"
Copy-Item -LiteralPath $sourceSevenZip -Destination $localSevenZip -Force
if (-not (Test-Path -LiteralPath $localSevenZip -PathType Leaf)) {
    throw "Не удалось скопировать 7za.exe: $localSevenZip"
}
Write-Host "Локальный 7za.exe готов."

$dbDir = Join-Path (Join-Path $configDir 'databases') $computer
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
if ($dbFiles.Count -eq 0) { throw "В каталоге нет JSON баз: $dbDir" }

$dumpDir = Join-Path $mcpWork 'dump'
$archiveDir = Join-Path $mcpWork 'archive'
New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null

function Get-DirectoryStatistics {
    param([string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction Stop)
    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    return [PSCustomObject]@{
        Count = $files.Count
        TotalBytes = [int64]$sum
    }
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

function Format-TimeSpan {
    param([TimeSpan]$Value)
    if ($Value.TotalDays -ge 1) { return $Value.ToString('d\.hh\:mm\:ss') }
    return $Value.ToString('hh\:mm\:ss')
}

function Invoke-Archive {
    param(
        [string]$SevenZip,
        [string]$ArchivePath,
        [string]$SourcePath,
        [string]$Id
    )

    if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
        Remove-Item -LiteralPath $ArchivePath -Force
    }

    $sourceStats = Get-DirectoryStatistics $SourcePath
    if ($sourceStats.Count -le 0 -or $sourceStats.TotalBytes -le 0) {
        throw "Dump пуст: $SourcePath"
    }

    $started = Get-Date
    $lastPercent = -1
    $lastOutput = ''

    Write-Host ""
    Write-Host "============================================================"
    Write-Host "Архивация: $Id"
    Write-Host "============================================================"
    Write-Host "Начало:           $($started.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "Источник:         $SourcePath"
    Write-Host "Файлов:           $($sourceStats.Count.ToString('N0'))"
    Write-Host "Размер источника: $(Format-Bytes $sourceStats.TotalBytes)"
    Write-Host "Архив:            $ArchivePath"
    Write-Host ""
    Write-Host "Архивация запущена..."

    # -bsp1 просит 7-Zip выводить процент текущей операции.
    # Прогресс читается через pipeline, поэтому консоль остается живой во время долгой упаковки.
    & $SevenZip 'a' '-t7z' '-mx=5' '-mmt=on' '-bsp1' $ArchivePath ($SourcePath + '\*') 2>&1 |
        ForEach-Object {
            $line = [string]$_
            $match = [regex]::Match($line, '(?<!\d)(\d{1,3})%(?!\d)')
            if ($match.Success) {
                $percent = [int]$match.Groups[1].Value
                if ($percent -ne $lastPercent) {
                    $lastPercent = $percent
                    $elapsed = (Get-Date) - $started
                    if ($percent -gt 0 -and $elapsed.TotalSeconds -gt 0) {
                        $estimatedTotalSeconds = $elapsed.TotalSeconds * 100.0 / $percent
                        $remainingSeconds = [math]::Max(0, $estimatedTotalSeconds - $elapsed.TotalSeconds)
                        $remaining = [TimeSpan]::FromSeconds($remainingSeconds)
                        $etaText = Format-TimeSpan $remaining
                    } else {
                        $etaText = '--:--:--'
                    }
                    $elapsedText = Format-TimeSpan $elapsed
                    Write-Host ("  Прогресс: {0,3}%   прошло: {1}   осталось: ~{2}" -f $percent,$elapsedText,$etaText)
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($line) -and $line -ne $lastOutput) {
                $lastOutput = $line
                Write-Host "  7za: $line"
            }
        }

    $rc = $LASTEXITCODE
    $finished = Get-Date
    $elapsed = $finished - $started

    if ($rc -ne 0) { throw "7za завершился с кодом $rc для $Id" }
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw "Архив не создан: $ArchivePath" }

    $archiveInfo = Get-Item -LiteralPath $ArchivePath
    $hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $shaFile = [IO.Path]::ChangeExtension($ArchivePath, '.sha256')
    ($hash + '  ' + [IO.Path]::GetFileName($ArchivePath)) | Set-Content -LiteralPath $shaFile -Encoding ASCII

    Write-Host ""
    Write-Host "Архивация завершена:"
    Write-Host "  Окончание:        $($finished.ToString('yyyy-MM-dd HH:mm:ss'))"
    Write-Host "  Время:            $(Format-TimeSpan $elapsed)"
    Write-Host "  Размер архива:    $(Format-Bytes ([int64]$archiveInfo.Length))"
    Write-Host "  Размер источника: $(Format-Bytes $sourceStats.TotalBytes)"
    if ($sourceStats.TotalBytes -gt 0) {
        $ratio = 100.0 * $archiveInfo.Length / $sourceStats.TotalBytes
        Write-Host ("  Размер архива:    {0:N2}% от исходного" -f $ratio)
    }
    Write-Host "  SHA-256:          $hash"
    Write-Host "  Контрольная сумма: $shaFile"
}

foreach ($dbFile in $dbFiles) {
    $db = Get-Content -Raw -LiteralPath $dbFile.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$db.db_source_id
    if ([string]::IsNullOrWhiteSpace($id)) { throw "В JSON отсутствует db_source_id: $($dbFile.FullName)" }

    $dumpRoot = Join-Path $dumpDir $id
    if (-not (Test-Path -LiteralPath $dumpRoot -PathType Container)) {
        throw "Не найден dump для ${id}: $dumpRoot"
    }

    $items = @(Get-ChildItem -LiteralPath $dumpRoot -Force)
    if ($items.Count -eq 0) { throw "Dump пуст: $dumpRoot" }

    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $archive = Join-Path $archiveDir ($id + '_' + $stamp + '.7z')
    Invoke-Archive -SevenZip $localSevenZip -ArchivePath $archive -SourcePath $dumpRoot -Id $id
}

Write-Host ""
Write-Host "============================================================"
Write-Host "PACK завершён успешно."
Write-Host "============================================================"
Write-Host "Локальный 7za.exe оставлен: $localSevenZip"
exit 0
