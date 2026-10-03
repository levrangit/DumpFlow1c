$ScriptVersion = 'v1.0.2'
$ScriptDate = '2026-10-03 00:53'
$ScriptName = 'dump_config.ps1'
Write-Host "DumpFlow1c: $ScriptName — $ScriptVersion — $ScriptDate"

# DumpFlow1c: v1.0.1 — 2026-10-03 06:43
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

Write-Host 'MCP - DUMP CONFIG'
Write-Host '------------------------------------------------------------'

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Файл не найден: $Path" }
    try { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Ошибка чтения JSON '$Path': $($_.Exception.Message)" }
}

function Write-Log {
    param([string]$Message,[string]$LogPath)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Get-DumpStatistics {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [PSCustomObject]@{ Count = 0; TotalBytes = [int64]0; LastWrite = $null }
    }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
    $sum = ($files | Measure-Object Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    $last = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    [PSCustomObject]@{
        Count = $files.Count
        TotalBytes = [int64]$sum
        LastWrite = if ($null -ne $last) { $last.LastWriteTime } else { $null }
    }
}

function Wait-DumpCompletion {
    param([string]$Path,[string]$Description,[string]$LogPath,[int]$StableSeconds = 30,[int]$CheckIntervalSeconds = 5,[int]$TimeoutMinutes = 60)
    $timeout = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastCount = -1
    $lastSize = -1
    $lastWrite = $null
    $stableSince = $null
    $seenFiles = $false

    Write-Log "Ожидание завершения: $Description" $LogPath
    while ($true) {
        if ((Get-Date) -gt $timeout) { throw "Таймаут ожидания выгрузки '$Description': $TimeoutMinutes мин." }

        $stats = Get-DumpStatistics $Path
        if ($stats.Count -gt 0) { $seenFiles = $true }
        $changed = ($stats.Count -ne $lastCount -or $stats.TotalBytes -ne $lastSize -or $stats.LastWrite -ne $lastWrite)

        if ($changed) {
            $lastCount = $stats.Count
            $lastSize = $stats.TotalBytes
            $lastWrite = $stats.LastWrite
            $stableSince = $null
            Write-Log ("Изменения: файлов={0}; размер={1} MB; последний файл={2}" -f $stats.Count,[math]::Round($stats.TotalBytes / 1MB,2),$stats.LastWrite) $LogPath
        }
        elseif ($seenFiles) {
            if ($null -eq $stableSince) { $stableSince = Get-Date }
            if (((Get-Date) - $stableSince).TotalSeconds -ge $StableSeconds) {
                Write-Log ("Каталог стабилен {0} сек.: файлов={1}; размер={2} MB" -f $StableSeconds,$stats.Count,[math]::Round($stats.TotalBytes / 1MB,2)) $LogPath
                return $stats
            }
        }
        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}

function Invoke-OneCDump {
    param(
        [string]$OneCExe,[string]$Server,[string]$Database,[string]$User,[string]$Password,
        [string]$OutputPath,[string]$Description,[string]$LogPath,[string]$ExtensionName
    )

    $source = "$Server\$Database"
    Write-Log "Запуск выгрузки: $Description" $LogPath
    Write-Log "Источник: $source" $LogPath
    Write-Log "Постоянный каталог: $OutputPath" $LogPath

    $logDirectory = Split-Path -Parent $LogPath
    $oneCLogPath = Join-Path $logDirectory ("1cv8_{0}_{1}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0,8)))

    if ([string]::IsNullOrWhiteSpace($ExtensionName)) {
        & $OneCExe DESIGNER /S $source /N $User /P $Password /DisableStartupDialogs /DumpConfigToFiles $OutputPath /Out $oneCLogPath
    }
    else {
        & $OneCExe DESIGNER /S $source /N $User /P $Password /DisableStartupDialogs /DumpConfigToFiles $OutputPath -Extension $ExtensionName /Out $oneCLogPath
    }

    $exitCode = $LASTEXITCODE
    Write-Log "Команда 1cv8.exe завершилась. EXIT CODE: $exitCode" $LogPath
    if ($exitCode -ne 0) { throw "1cv8.exe завершился с кодом ${exitCode}: $Description" }

    $stats = Wait-DumpCompletion $OutputPath $Description $LogPath
    if ($stats.Count -le 0) { throw "Выгрузка завершилась без файлов: $Description" }
    return $stats
}

$computerName = $env:COMPUTERNAME
$terminalPath = Join-Path $root ("config\terminals\{0}.json" -f $computerName)
if (-not (Test-Path -LiteralPath $terminalPath -PathType Leaf)) { throw "Не найден файл терминала: $terminalPath" }
$terminal = Read-JsonFile $terminalPath
if ([string]$terminal.computer_name -ne $computerName) { throw 'computer_name в terminal JSON не совпадает с COMPUTERNAME.' }
$projectName = [string]$terminal.project_name
if ([string]::IsNullOrWhiteSpace($projectName)) { throw 'В terminal JSON не задан project_name.' }

$mcpWork = [string]$terminal.mcp_work
$onecBin = [string]$terminal.onec_bin

if (-not (Test-Path -LiteralPath $mcpWork -PathType Container)) { throw "Рабочий каталог MCP не найден: $mcpWork" }
if (-not (Test-Path -LiteralPath $onecBin -PathType Leaf)) { throw "1cv8.exe не найден: $onecBin" }

$dumpRoot = Join-Path (Join-Path $mcpWork 'dump') $projectName
$logsRoot = Join-Path $mcpWork 'logs'
New-Item -ItemType Directory -Path $dumpRoot,$logsRoot -Force | Out-Null
$logPath = Join-Path $logsRoot ("dump_config_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$dbDir = Join-Path $root ("config\databases\{0}" -f $computerName)
if (-not (Test-Path -LiteralPath $dbDir -PathType Container)) { throw "Каталог конфигураций баз не найден: $dbDir" }
$dbFiles = @(Get-ChildItem -LiteralPath $dbDir -Filter '*.json' -File | Sort-Object Name)
if ($dbFiles.Count -eq 0) { throw "Не найдено ни одного JSON базы: $dbDir" }

Write-Log "Проект: $projectName" $logPath
Write-Log "Компьютер: $computerName" $logPath
Write-Log "Рабочий каталог: $mcpWork" $logPath
Write-Log "Каталог dump проекта: $dumpRoot" $logPath
Write-Log "Баз найдено: $($dbFiles.Count)" $logPath

$ids = @{}
foreach ($file in $dbFiles) {
    $db = Read-JsonFile $file.FullName
    $id = [string]$db.db_source_id
    if ([string]::IsNullOrWhiteSpace($id)) { throw "В файле '$($file.FullName)' отсутствует db_source_id." }
    if ($ids.ContainsKey($id)) { throw "DB_SOURCE_ID не уникален: $id" }
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Некорректный DB_SOURCE_ID: $id" }
    $ids[$id] = $file.FullName
    if ($file.Name -ne "$id.json") { throw "Имя файла '$($file.Name)' не совпадает с DB_SOURCE_ID '$id'." }
}

foreach ($dbFile in $dbFiles) {
    $db = Read-JsonFile $dbFile.FullName
    $id = [string]$db.db_source_id
    $server = [string]$db.db_server
    $database = [string]$db.db_database
    $user = [string]$db.db_user
    $password = [string]$db.db_password

    if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($database) -or [string]::IsNullOrWhiteSpace($user)) {
        throw "Не заполнены параметры подключения для '$id'."
    }

    $dumpPath = Join-Path $dumpRoot $id
    $configPath = Join-Path $dumpPath 'config'
    $extensionsPath = Join-Path $dumpPath 'extensions'
    New-Item -ItemType Directory -Path $configPath,$extensionsPath -Force | Out-Null

    $extensions = @($db.extensions)
    $configuredExtensions = @($extensions | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # Удаляем только каталоги расширений, которых больше нет в настройках.
    # Каталог основной конфигурации не заменяется и не удаляется:
    # это позволяет 1С использовать ConfigDumpInfo.xml для инкрементальной выгрузки.
    foreach ($oldExtensionDir in @(Get-ChildItem -LiteralPath $extensionsPath -Directory -ErrorAction SilentlyContinue)) {
        if ($configuredExtensions -notcontains $oldExtensionDir.Name) {
            Remove-Item -LiteralPath $oldExtensionDir.FullName -Recurse -Force
            Write-Log "Удалено неактуальное расширение из dump: $($oldExtensionDir.Name)" $logPath
        }
    }

    try {
        Write-Log "============================================================" $logPath
        Write-Log "Выгрузка базы: $id" $logPath
        Write-Log "Постоянный dump: $dumpPath" $logPath

        Invoke-OneCDump $onecBin $server $database $user $password $configPath "$id / основная конфигурация" $logPath

        foreach ($extensionName in $configuredExtensions) {
            $extensionPath = Join-Path $extensionsPath $extensionName
            New-Item -ItemType Directory -Path $extensionPath -Force | Out-Null
            Invoke-OneCDump $onecBin $server $database $user $password $extensionPath "$id / расширение $extensionName" $logPath $extensionName
        }

        $finalStats = Get-DumpStatistics $dumpPath
        if ($finalStats.Count -le 0) { throw "Dump пуст: $dumpPath" }
        Write-Log ("База '$id' успешно выгружена: файлов={0}; размер={1} MB" -f $finalStats.Count,[math]::Round($finalStats.TotalBytes / 1MB,2)) $logPath
    }
    catch {
        Write-Log ("ОШИБКА базы '$id': {0}" -f $_.Exception.Message) $logPath
        throw
    }
}

Write-Log 'DUMP CONFIG завершён успешно.' $logPath
exit 0
