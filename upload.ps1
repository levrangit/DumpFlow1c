#Requires -Version 5.1
# Если PowerShell запрещает запуск скрипта, выполните:
# Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
# Проверить текущую политику:
# Get-ExecutionPolicy -List

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configDir = Join-Path $root 'config'
$commonPath = Join-Path $configDir 'common.json'

Write-Host "------------------------------------------------------------"
Write-Host "MCP - UPLOAD"
Write-Host "------------------------------------------------------------"

if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Не найден common.json: $commonPath"
}

$common = Get-Content -Raw -LiteralPath $commonPath -Encoding UTF8 | ConvertFrom-Json
$rdpDrive = [string]$common.rdp_drive
$mcpPath = [string]$common.mcp_path

if ([string]::IsNullOrWhiteSpace($rdpDrive)) { throw "В common.json не задан rdp_drive." }
if ([string]::IsNullOrWhiteSpace($mcpPath)) { throw "В common.json не задан mcp_path." }
if (-not (Test-Path -LiteralPath $rdpDrive)) {
    throw "RDP-диск недоступен: $rdpDrive"
}

$rdpMcp = Join-Path $rdpDrive $mcpPath
if (-not (Test-Path -LiteralPath $rdpMcp -PathType Container)) {
    throw "Каталог MCP на RDP-диске не найден: $rdpMcp"
}

$rclone = Join-Path (Join-Path $root 'tools') 'rclone.exe'
if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) {
    throw "Не найден rclone.exe: $rclone"
}

$computer = $env:COMPUTERNAME
$terminalPath = Join-Path (Join-Path $configDir 'terminals') ($computer + '.json')
if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) {
    throw "Не найден файл терминала: $terminalPath"
}

$terminal = Get-Content -Raw -LiteralPath $terminalPath -Encoding UTF8 | ConvertFrom-Json
$mcpWork = [string]$terminal.mcp_work
if ([string]::IsNullOrWhiteSpace($mcpWork)) {
    throw "В конфигурации терминала не указан mcp_work: $terminalPath"
}

$archiveDir = Join-Path $mcpWork 'archive'
if (-not (Test-Path -LiteralPath $archiveDir -PathType Container)) {
    throw "Локальный каталог archive не найден: $archiveDir"
}

$archiveFiles = @(Get-ChildItem -LiteralPath $archiveDir -File | Where-Object { $_.Extension -in @('.7z', '.sha256') } | Sort-Object Name)
if ($archiveFiles.Count -eq 0) {
    throw "В каталоге archive нет файлов .7z/.sha256: $archiveDir"
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1TB) { return ("{0:N2} TB" -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

$totalBytes = [int64](($archiveFiles | Measure-Object -Property Length -Sum).Sum)
$archiveDestination = Join-Path $rdpMcp 'archive'
$controlDestination = Join-Path $rdpMcp 'control'
New-Item -ItemType Directory -Force -Path $archiveDestination | Out-Null
New-Item -ItemType Directory -Force -Path $controlDestination | Out-Null

# Создаём control.json до начала передачи.
$sevenZipFiles = @($archiveFiles | Where-Object { $_.Extension -eq '.7z' })
if ($sevenZipFiles.Count -eq 0) {
    throw "В каталоге archive нет архивов .7z: $archiveDir"
}

$manifestArchives = @(
    foreach ($file in $sevenZipFiles) {
        [PSCustomObject]@{
            Name       = $file.Name
            Length     = [int64]$file.Length
            SizeBytes  = [int64]$file.Length
            Sha256File = (([IO.Path]::ChangeExtension($file.Name, '.sha256')))
        }
    }
)

$manifest = [PSCustomObject]@{
    Version = 1
    CreatedAt = (Get-Date).ToString('o')
    SourceArchiveDirectory = $archiveDir
    ArchiveCount = $manifestArchives.Count
    Sha256Count = $manifestArchives.Count
    TotalArchiveBytes = [int64](($sevenZipFiles | Measure-Object -Property Length -Sum).Sum)
    Archives = $manifestArchives
}

$controlJson = Join-Path $controlDestination 'control.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $controlJson -Encoding UTF8

Write-Host ""
Write-Host "Контрольный файл создан: $controlJson"
Write-Host ("Архивов: {0:N0}" -f $manifest.ArchiveCount)
Write-Host ("Размер архивов: {0}" -f (Format-Bytes $manifest.TotalArchiveBytes))

Write-Host ""
Write-Host "Архивов для передачи: $($archiveFiles.Count)"
Write-Host ("Общий размер: {0}" -f (Format-Bytes $totalBytes))
Write-Host "FROM: $archiveDir"
Write-Host "TO:   $archiveDestination"
Write-Host ""

# Передаём только готовые архивы и контрольные суммы.
# dump\... в upload больше не используется.
& $rclone copy $archiveDir $archiveDestination --include '*.7z' --include '*.sha256' --transfers 1 --checkers 2 --progress --stats 5s --verbose
$rc = $LASTEXITCODE

if ($rc -ne 0) {
    throw "rclone завершился с кодом $rc при передаче archive."
}

Write-Host ""
Write-Host "UPLOAD завершён успешно."
Write-Host "Переданы только архивные файлы .7z и .sha256."
exit 0
