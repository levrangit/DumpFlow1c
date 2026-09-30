#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path = 'L:\!work\RAU_IT\MCP'
)

$ErrorActionPreference = 'Stop'

$controlPath = Join-Path $path 'control_upload\control_upload.json'
$archiveDir = Join-Path $path 'archive'

if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Папка назначения не найдена: $path" }
if (-not (Test-Path -LiteralPath $controlPath -PathType Leaf)) { throw "Не найден контрольный файл: $controlPath" }

$control = Get-Content -Raw -LiteralPath $controlPath -Encoding UTF8 | ConvertFrom-Json
$expected = @($control.Transfers)
if ($expected.Count -eq 0) { throw 'В control_upload.json нет Transfers.' }

function Format-Bytes([int64]$Bytes) {
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

function Test-File([string]$Path,[int64]$SizeBytes) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ([int64](Get-Item -LiteralPath $Path).Length -eq $SizeBytes)
}

function Get-Md5([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToUpperInvariant()
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

Write-Host '------------------------------------------------------------'
Write-Host 'MCP - CONTROL_UPLOAD'
Write-Host '------------------------------------------------------------'
Write-Host "Проект: $($control.Project)"
Write-Host "Источник: $($control.SourceComputer)"
Write-Host "Control: $controlPath"
Write-Host ''

$start = Get-Date
while ($true) {
    $allComplete = $true
    $totalBytes = [int64]0
    $receivedBytes = [int64]0
    $completeFiles = 0
    $totalFiles = $expected.Count * 4

    foreach ($item in $expected) {
        $database = [string]$item.Database
        $snapshot = [string]$item.SnapshotId
        Write-Host ("[{0}] {1} / {2}" -f (Get-Date -Format 'HH:mm:ss'),$database,$snapshot)

        $checks = @(
            [PSCustomObject]@{ Label='7z'; Path=(Join-Path $archiveDir $item.Archive.Name); Size=[int64]$item.Archive.SizeBytes; Kind='SHA256'; Hash=[string]$item.Archive.SHA256 },
            [PSCustomObject]@{ Label='SHA256'; Path=(Join-Path $archiveDir $item.ArchiveChecksum.Name); Size=[int64]$item.ArchiveChecksum.SizeBytes; Kind='NONE'; Hash='' },
            [PSCustomObject]@{ Label='manifest'; Path=(Join-Path $archiveDir $item.Manifest.Name); Size=[int64]$item.Manifest.SizeBytes; Kind='MD5'; Hash=[string]$item.Manifest.MD5 },
            [PSCustomObject]@{ Label='changes'; Path=(Join-Path $archiveDir $item.Changes.Name); Size=[int64]$item.Changes.SizeBytes; Kind='MD5'; Hash=[string]$item.Changes.MD5 }
        )

        foreach ($check in $checks) {
            $totalBytes += $check.Size
            if (Test-File $check.Path $check.Size) {
                $receivedBytes += $check.Size
                $completeFiles++
                $valid = $true
                if ($check.Kind -eq 'SHA256') { $valid = ((Get-Sha256 $check.Path) -eq $check.Hash) }
                elseif ($check.Kind -eq 'MD5') { $valid = ((Get-Md5 $check.Path) -eq $check.Hash) }
                $mark = if ($valid) { 'OK' } else { 'HASH ERROR' }
                Write-Host ("  {0,-8} {1,-10} {2}" -f $check.Label,$mark,$check.Path)
                if (-not $valid) { $allComplete = $false }
            }
            else {
                Write-Host ("  {0,-8} {1}" -f $check.Label,'ожидание...')
                $allComplete = $false
            }
        }
    }

    $percent = if ($totalBytes -gt 0) { 100.0 * $receivedBytes / $totalBytes } else { 100.0 }
    Write-Host ''
    Write-Host ("Прогресс: {0:N2}% | Файлов: {1}/{2} | Размер: {3}/{4}" -f $percent,$completeFiles,$totalFiles,(Format-Bytes $receivedBytes),(Format-Bytes $totalBytes))

    if ($allComplete) {
        Write-Host ''
        Write-Host '============================================================'
        Write-Host 'CONTROL_UPLOAD: ПЕРЕДАЧА ЗАВЕРШЕНА УСПЕШНО'
        Write-Host '============================================================'
        Write-Host ("Время: {0}" -f ((Get-Date) - $start))
        exit 0
    }

    Start-Sleep -Seconds 2
}
