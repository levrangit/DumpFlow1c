$ScriptVersion = 'v1.0.3'
$ScriptDate = '2026-10-03 13:40'
$ScriptName = 'update.ps1'
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Write-UpdateLog {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    Write-Host $line
    if ($script:UpdateLogPath) {
        Add-Content -LiteralPath $script:UpdateLogPath -Value $line -Encoding UTF8
    }
}

function Invoke-LoggedScript {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    Write-UpdateLog ("Запуск: {0} {1}" -f $ScriptPath, ($Arguments -join ' '))

    & $ScriptPath @Arguments 2>&1 |
        ForEach-Object {
            $line = $_ | Out-String -Width 4096
            $line = $line.TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host $line
                Add-Content -LiteralPath $script:UpdateLogPath -Value $line -Encoding UTF8
            }
        }

    $exitCode = $LASTEXITCODE
    Write-UpdateLog ("Завершён: {0}; EXIT CODE: {1}" -f $ScriptPath, $exitCode)

    if ($exitCode -ne 0) {
        throw "{0} завершился с кодом {1}." -f ([IO.Path]::GetFileName($ScriptPath)), $exitCode
    }
}

$skipPrepare = $false
$skipDumpConfig = $false
$skipManifest = $false
$skipCompareManifests = $false
$skipPack = $false
$skipUpload = $false

foreach ($argument in $args) {
    switch ($argument) {
        '--NoPrepare'             { $skipPrepare = $true; continue }
        '--NoDump_config'        { $skipDumpConfig = $true; continue }
        '--NoManifest'           { $skipManifest = $true; continue }
        '--NoCompare_manifests'  { $skipCompareManifests = $true; continue }
        '--NoPack'               { $skipPack = $true; continue }
        '--NoUpload'             { $skipUpload = $true; continue }
        default { throw "Неизвестный флаг update.ps1: $argument" }
    }
}

if (-not $skipPrepare) {
    Invoke-LoggedScript (Join-Path $root 'prepare.ps1')
} else {
    Write-Host 'Пропуск prepare.ps1 (--NoPrepare).'
}

if (-not $skipDumpConfig) {
    Invoke-LoggedScript (Join-Path $root 'dump_config.ps1')
} else {
    Write-Host 'Пропуск dump_config.ps1 (--NoDump_config).'
}

$computer = $env:COMPUTERNAME
$terminalPath = Join-Path $root ("config\terminals\{0}.json" -f $computer)
if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) { throw "Не найден файл терминала: $terminalPath" }
$terminal = Get-Content -Raw -LiteralPath $terminalPath -Encoding UTF8 | ConvertFrom-Json
$projectName = [string]$terminal.project_name
$mcpWork = [string]$terminal.mcp_work
if ([string]::IsNullOrWhiteSpace($projectName)) { throw 'В terminal JSON не задан project_name.' }
if ([string]::IsNullOrWhiteSpace($mcpWork)) { throw 'В terminal JSON не задан mcp_work.' }

$logsRoot = Join-Path $mcpWork 'logs'
New-Item -ItemType Directory -Force -Path $logsRoot | Out-Null
$script:UpdateLogPath = Join-Path $logsRoot ("update_{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0,8)))

Write-UpdateLog ("DumpFlow1c: {0} — {1} — {2}" -f $ScriptName, $ScriptVersion, $ScriptDate)
Write-UpdateLog ("Компьютер: {0}" -f $computer)
Write-UpdateLog ("Проект: {0}" -f $projectName)
Write-UpdateLog ("Рабочий каталог: {0}" -f $mcpWork)
Write-UpdateLog '============================================================'
Write-UpdateLog 'MCP - UPDATE'
Write-UpdateLog '============================================================'

$dumpRoot = Join-Path (Join-Path $mcpWork 'dump') $projectName
$metadataRoot = Join-Path (Join-Path $mcpWork 'metadata') $projectName
New-Item -ItemType Directory -Force -Path $metadataRoot | Out-Null

$dbDir = Join-Path $root ("config\databases\{0}" -f $computer)
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
if ($dbFiles.Count -eq 0) { throw "Не найдено JSON баз: $dbDir" }

foreach ($dbFile in $dbFiles) {
    $db = Get-Content -Raw -LiteralPath $dbFile.FullName -Encoding UTF8 | ConvertFrom-Json
    $id = [string]$db.db_source_id
    $dumpPath = Join-Path $dumpRoot $id
    $metadataDir = Join-Path $metadataRoot $id
    New-Item -ItemType Directory -Force -Path $metadataDir | Out-Null

    if (-not $skipManifest) {
        Invoke-LoggedScript (Join-Path $root 'manifest.ps1') @('-DatabaseName', $id)
    } else {
        Write-Host "Пропуск manifest.ps1 для $id (--NoManifest)."
    }

    if (-not $skipCompareManifests) {
        Invoke-LoggedScript (Join-Path $root 'compare_manifests.ps1') @('-DatabaseName', $id)
    } else {
        Write-Host "Пропуск compare_manifests.ps1 для $id (--NoCompare_manifests)."
    }
}

if (-not $skipPack) {
    Invoke-LoggedScript (Join-Path $root 'pack.ps1')
} else {
    Write-Host 'Пропуск pack.ps1 (--NoPack).'
}

if (-not $skipUpload) {
    Invoke-LoggedScript (Join-Path $root 'upload.ps1')
} else {
    Write-Host 'Пропуск upload.ps1 (--NoUpload).'
}

Write-UpdateLog 'MCP UPDATE COMPLETED'
Write-UpdateLog ("Лог полного запуска: {0}" -f $script:UpdateLogPath)
exit 0
