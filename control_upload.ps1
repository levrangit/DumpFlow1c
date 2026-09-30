# DumpFlow1c: версия файла — 2026-09-30 23:32
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path = 'L:\!work\RAU_IT\MCP'
)

$ErrorActionPreference = 'Stop'

$controlPath = Join-Path $Path 'control_upload\control_upload.json'
$archiveDir = Join-Path $Path 'archive'

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Папка назначения не найдена: $Path" }
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

function Test-File([string]$FilePath,[int64]$SizeBytes) {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return $false }
    return ([int64](Get-Item -LiteralPath $FilePath).Length -eq $SizeBytes)
}

function Get-Md5([string]$FilePath) {
    return (Get-FileHash -LiteralPath $FilePath -Algorithm MD5).Hash.ToUpperInvariant()
}

function Get-Sha256([string]$FilePath) {
    return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-ShaSidecar([string]$ShaPath,[string]$ArchiveName,[string]$ExpectedHash) {
    if (-not (Test-Path -LiteralPath $ShaPath -PathType Leaf)) { return $false }

    $line = @(Get-Content -LiteralPath $ShaPath -Encoding ASCII |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1)

    if ($line.Count -eq 0) { return $false }

    $text = ([string]$line[0]).Trim()
    if ($text -notmatch '^([0-9A-Fa-f]{64})\s+(.+)$') { return $false }

    $actualHash = $matches[1]
    $actualName = $matches[2].Trim()

    if (-not $actualHash.Equals($ExpectedHash,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $actualName -eq $ArchiveName
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
            [PSCustomObject]@{
                Label='7z'
                Path=(Join-Path $archiveDir $item.Archive.Name)
                Size=[int64]$item.Archive.SizeBytes
                Kind='SHA256'
                Hash=[string]$item.Archive.SHA256
            },
            [PSCustomObject]@{
                Label='SHA256'
                Path=(Join-Path $archiveDir $item.ArchiveChecksum.Name)
                Size=[int64]$item.ArchiveChecksum.SizeBytes
                Kind='SIDECAR'
                Hash=[string]$item.Archive.SHA256
            },
            [PSCustomObject]@{
                Label='manifest'
                Path=(Join-Path $archiveDir $item.Manifest.Name)
                Size=[int64]$item.Manifest.SizeBytes
                Kind='MD5'
                Hash=[string]$item.Manifest.MD5
            },
            [PSCustomObject]@{
                Label='changes'
                Path=(Join-Path $archiveDir $item.Changes.Name)
                Size=[int64]$item.Changes.SizeBytes
                Kind='MD5'
                Hash=[string]$item.Changes.MD5
            }
        )

        foreach ($check in $checks) {
            $totalBytes += $check.Size

            if (Test-File $check.Path $check.Size) {
                $receivedBytes += $check.Size
                $completeFiles++

                $valid = switch ($check.Kind) {
                    'SHA256' { (Get-Sha256 $check.Path) -eq $check.Hash; break }
                    'MD5' { (Get-Md5 $check.Path) -eq $check.Hash; break }
                    'SIDECAR' { Test-ShaSidecar $check.Path ([string]$item.Archive.Name) $check.Hash; break }
                    default { $false }
                }

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
    Write-Host ("Прогресс: {0:N2}% | Файлов: {1}/{2} | Размер: {3}/{4}" -f
        $percent,$completeFiles,$totalFiles,
        (Format-Bytes $receivedBytes),(Format-Bytes $totalBytes))

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
