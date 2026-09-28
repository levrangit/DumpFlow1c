#Requires -Version 5.1
# Если PowerShell запрещает запуск скрипта, выполните:
# Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
# Проверить текущую политику:
# Get-ExecutionPolicy -List

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$configDir = Join-Path $root 'config'

Write-Host "------------------------------------------------------------"
Write-Host "MCP - PREPARE"
Write-Host "------------------------------------------------------------"

$commonPath = Join-Path $configDir 'common.json'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) { throw "Не найден config\common.json." }

$common = Get-Content -Raw -LiteralPath $commonPath -Encoding UTF8 | ConvertFrom-Json
$rdpDrive = [string]$common.rdp_drive
$mcpPath = [string]$common.mcp_path
if ([string]::IsNullOrWhiteSpace($rdpDrive)) { throw "В common.json не задан rdp_drive." }
if ([string]::IsNullOrWhiteSpace($mcpPath)) { throw "В common.json не задан mcp_path." }
if (-not (Test-Path -LiteralPath $rdpDrive)) { throw "RDP-диск недоступен: $rdpDrive" }

$rdpMcp = Join-Path $rdpDrive $mcpPath
$rdpControl = Join-Path $rdpMcp 'control'
New-Item -ItemType Directory -Force -Path $rdpControl | Out-Null
Write-Host "MCP на RDP-диске: $rdpMcp"
Write-Host "Control на RDP-диске: $rdpControl"

$computer = $env:COMPUTERNAME
$terminalPath = Join-Path (Join-Path $configDir 'terminals') ($computer + '.json')
if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) { throw "Не найден файл терминала: $terminalPath" }

$terminal = Get-Content -Raw -LiteralPath $terminalPath -Encoding UTF8 | ConvertFrom-Json
if ([string]$terminal.computer_name -ne $computer) { throw "computer_name в terminal JSON не совпадает с COMPUTERNAME." }

$mcpWork = [string]$terminal.mcp_work
$onecBin = [string]$terminal.onec_bin
if ([string]::IsNullOrWhiteSpace($mcpWork)) { throw "В terminal JSON не задан mcp_work." }
if ([string]::IsNullOrWhiteSpace($onecBin)) { throw "В terminal JSON не задан onec_bin." }
if (-not (Test-Path -LiteralPath $mcpWork -PathType Container)) { throw "Рабочий каталог не найден: $mcpWork" }
if (-not (Test-Path -LiteralPath $onecBin -PathType Leaf)) { throw "Не найден 1cv8.exe: $onecBin" }

$toolsDir = Join-Path $root 'tools'
$rclone = Join-Path $toolsDir 'rclone.exe'
$sevenZip = Join-Path $toolsDir '7za.exe'
if (-not (Test-Path -LiteralPath $rclone -PathType Leaf)) { throw "Не найден rclone.exe: $rclone" }
if (-not (Test-Path -LiteralPath $sevenZip -PathType Leaf)) { throw "Не найден 7za.exe: $sevenZip" }

$dumpDir = Join-Path $mcpWork 'dump'
$archiveDir = Join-Path $mcpWork 'archive'
$logsDir = Join-Path $mcpWork 'logs'
New-Item -ItemType Directory -Force -Path $dumpDir, $archiveDir, $logsDir | Out-Null

$dbDir = Join-Path (Join-Path $configDir 'databases') $computer
if (-not (Test-Path -LiteralPath $dbDir -PathType Container)) { throw "Не найден каталог баз: $dbDir" }
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File)
if ($dbFiles.Count -eq 0) { throw "В каталоге нет JSON баз: $dbDir" }

$allDbRoot = Join-Path $configDir 'databases'
$seen = @{}
foreach ($file in @(Get-ChildItem -LiteralPath $allDbRoot -Filter '*.json' -File -Recurse)) {
    $j = Get-Content -Raw -LiteralPath $file.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$j.db_source_id
    if ([string]::IsNullOrWhiteSpace($id)) { throw "В JSON не задан db_source_id: $($file.FullName)" }
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Некорректный DB_SOURCE_ID: $id" }
    if ($seen.ContainsKey($id)) { throw "DB_SOURCE_ID не уникален: $id" }
    $seen[$id] = $file.FullName
    if ([IO.Path]::GetFileNameWithoutExtension($file.Name) -ne $id) { throw "Имя JSON должно совпадать с DB_SOURCE_ID: $($file.FullName)" }
}

foreach ($file in $dbFiles) {
    $db = Get-Content -Raw -LiteralPath $file.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$db.db_source_id
    $sourceDump = Join-Path $dumpDir $id
    $configDump = Join-Path $sourceDump 'config'
    $extensionsDump = Join-Path $sourceDump 'extensions'
    New-Item -ItemType Directory -Force -Path $configDump, $extensionsDump | Out-Null

    $extensions = @($db.extensions)
    if ($extensions.Count -eq 0) { throw "Для базы $id не задано ни одного расширения." }
    foreach ($extValue in $extensions) {
        $ext = [string]$extValue
        if ([string]::IsNullOrWhiteSpace($ext)) { throw "Пустое имя расширения в $($file.FullName)" }
        New-Item -ItemType Directory -Force -Path (Join-Path $extensionsDump $ext) | Out-Null
    }
    Write-Host "Подготовлена база: $id"
}

Write-Host "Компьютер: $computer"
Write-Host "Рабочий каталог: $mcpWork"
Write-Host "1cv8.exe: $onecBin"
Write-Host "Баз найдено: $($dbFiles.Count)"
Write-Host "PREPARE завершён."
exit 0
