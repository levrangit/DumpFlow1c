#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path = 'L:\!work\RAU_IT\MCP'
)

$ScriptVersion = 'v1.0.6'
$ScriptDate = '2026-10-03 13:20'
$ScriptName = 'control_upload.ps1'
Write-Host "DumpFlow1c: $ScriptName — $ScriptVersion — $ScriptDate"

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

function Get-Md5([string]$FilePath) { return (Get-FileHash -LiteralPath $FilePath -Algorithm MD5).Hash.ToUpperInvariant() }
function Get-Sha256([string]$FilePath) { return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToUpperInvariant() }

function Test-ShaSidecar([string]$ShaPath,[string]$ArchiveName,[string]$ExpectedHash) {
    if (-not (Test-Path -LiteralPath $ShaPath -PathType Leaf)) { return $false }
    $line = @(Get-Content -LiteralPath $ShaPath -Encoding ASCII | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($line.Count -eq 0) { return $false }
    $text = ([string]$line[0]).Trim()
    if ($text -notmatch '^([0-9A-Fa-f]{64})\s+(.+)$') { return $false }
    $actualHash = $matches[1]
    $actualName = $matches[2].Trim()
    if (-not $actualHash.Equals($ExpectedHash,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $actualName -eq $ArchiveName
}

function Get-CheckState([string]$Label,[string]$Path,[int64]$Size,[string]$Kind,[string]$Hash,[string]$ArchiveName) {
    if (-not (Test-File $Path $Size)) {
        return [PSCustomObject]@{ Label=$Label; State='ожидание'; Size=$Size; Received=$false; Valid=$false }
    }
    $valid = switch ($Kind) {
        'SHA256' { (Get-Sha256 $Path) -eq $Hash; break }
        'MD5' { (Get-Md5 $Path) -eq $Hash; break }
        'SIDECAR' { Test-ShaSidecar $Path $ArchiveName $Hash; break }
        default { $false }
    }
    return [PSCustomObject]@{ Label=$Label; State=if ($valid) { 'OK' } else { 'HASH ERROR' }; Size=$Size; Received=$true; Valid=$valid }
}

function Write-Status([string]$Text) {
    # Статус должен физически помещаться в одну строку консоли.
    # Иначе перенос строки делает перерисовку через CR визуально некорректной.
    $width = 120
    try {
        if ([Console]::WindowWidth -gt 10) {
            $width = [Console]::WindowWidth - 1
        }
    } catch { }

    if ($Text.Length -gt $width) {
        $Text = $Text.Substring(0, $width - 3) + '...'
    }

    [Console]::Write(("`r" + $Text.PadRight($width)))
}

Write-Host '------------------------------------------------------------'
Write-Host 'MCP - CONTROL_UPLOAD'
Write-Host '------------------------------------------------------------'
Write-Host "Проект: $($control.Project)"
Write-Host "Источник: $($control.SourceComputer)"
Write-Host "Control: $controlPath"
Write-Host ''

$start = Get-Date
$script:StatusWidth = 0

while ($true) {
    $allComplete = $true
    $totalBytes = [int64]0
    $receivedBytes = [int64]0
    $completeFiles = 0
    $totalFiles = $expected.Count * 4
    $databaseParts = @()

    foreach ($item in $expected) {
        $database = [string]$item.Database
        $snapshot = [string]$item.SnapshotId
        $checks = @(
            (Get-CheckState '7z' (Join-Path $archiveDir $item.Archive.Name) ([int64]$item.Archive.SizeBytes) 'SHA256' ([string]$item.Archive.SHA256) ([string]$item.Archive.Name)),
            (Get-CheckState 'SHA256' (Join-Path $archiveDir $item.ArchiveChecksum.Name) ([int64]$item.ArchiveChecksum.SizeBytes) 'SIDECAR' ([string]$item.Archive.SHA256) ([string]$item.Archive.Name)),
            (Get-CheckState 'manifest' (Join-Path $archiveDir $item.Manifest.Name) ([int64]$item.Manifest.SizeBytes) 'MD5' ([string]$item.Manifest.MD5) ([string]$item.Archive.Name)),
            (Get-CheckState 'changes' (Join-Path $archiveDir $item.Changes.Name) ([int64]$item.Changes.SizeBytes) 'MD5' ([string]$item.Changes.MD5) ([string]$item.Archive.Name))
        )
        $shortStates = @()
        foreach ($check in $checks) {
            $totalBytes += $check.Size
            if ($check.Received) {
                $receivedBytes += $check.Size
                $completeFiles++
                if (-not $check.Valid) { $allComplete = $false }
            } else {
                $allComplete = $false
            }
            $shortStates += "$($check.Label)=$($check.State)"
        }

        # Для двух баз оставляем только компактное состояние файлов,
        # чтобы вся строка гарантированно помещалась в окно консоли.
        $compact = ($shortStates -join ',')
        $databaseParts += "$database=$compact"
    }

    $percent = if ($totalBytes -gt 0) { 100.0 * $receivedBytes / $totalBytes } else { 100.0 }
    $status = ("[{0}] | {1:N2}% | {2}/{3} | {4}/{5} | {6}" -f (Get-Date -Format "HH:mm:ss"), $percent, $completeFiles, $totalFiles, (Format-Bytes $receivedBytes), (Format-Bytes $totalBytes), ($databaseParts -join " | "))
    Write-Status $status

    if ($allComplete) {
        Write-Host ''
        Write-Host ''
        Write-Host '============================================================'
        Write-Host 'CONTROL_UPLOAD: ПЕРЕДАЧА ЗАВЕРШЕНА УСПЕШНО'
        Write-Host '============================================================'
        Write-Host ("Время: {0}" -f ((Get-Date) - $start))
        exit 0
    }
    Start-Sleep -Seconds 2
}
