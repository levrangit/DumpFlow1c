# curl.exe -L "https://raw.githubusercontent.com/levrangit/levran-ai-memory/main/src/setup.ps1" -o ".\setup.ps1"
﻿#requires -Version 5.1
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$McpProject = $ScriptDir
$ConfigDir = Join-Path $McpProject 'config'
$TerminalsDir = Join-Path $ConfigDir 'terminals'
$DatabasesDir = Join-Path $ConfigDir 'databases'

New-Item -ItemType Directory -Force -Path $ConfigDir, $TerminalsDir, $DatabasesDir | Out-Null

$CommonJson = Join-Path $ConfigDir 'common.json'
$Computer = $env:COMPUTERNAME
$UserName = $env:USERNAME
$TerminalJson = Join-Path $TerminalsDir "$Computer.json"
$DatabaseDir = Join-Path $DatabasesDir $Computer

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json)
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $Object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Load-Common {
    $script:Common = Read-JsonFile -Path $CommonJson
    if ($null -eq $Common) {
        $script:Common = [ordered]@{
            rdp_drive = '\\tsclient\L'
            mcp_path  = '!work\RAU_IT\MCP'
        }
        Save-JsonFile -Path $CommonJson -Object $Common
    }

    if ([string]::IsNullOrWhiteSpace($Common.rdp_drive)) {
        $Common.rdp_drive = '\\tsclient\L'
    }
    if ([string]::IsNullOrWhiteSpace($Common.mcp_path)) {
        $Common.mcp_path = '!work\RAU_IT\MCP'
    }

    $script:RdpDrive = [string]$Common.rdp_drive
    $script:McpPath = [string]$Common.mcp_path
}

function Load-Terminal {
    $script:Terminal = Read-JsonFile -Path $TerminalJson

    if ($null -eq $Terminal) {
        $script:McpWork = ''
        $script:OnecBin = ''
    }
    else {
        $script:McpWork = [string]$Terminal.mcp_work
        $script:OnecBin = [string]$Terminal.onec_bin
    }
}

function Save-Common {
    $obj = [ordered]@{
        rdp_drive = $RdpDrive
        mcp_path  = $McpPath
    }
    Save-JsonFile -Path $CommonJson -Object $obj
}

function Save-Terminal {
    $obj = [ordered]@{
        computer_name = $Computer
        username      = $UserName
        mcp_work      = $McpWork
        onec_bin      = $OnecBin
    }
    Save-JsonFile -Path $TerminalJson -Object $obj
}

function Validate-SourceId {
    param([string]$Id)

    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        Write-Host 'Некорректный DB_SOURCE_ID.' -ForegroundColor Red
        Write-Host 'Разрешены только латинские буквы, цифры, "_" и "-".'
        return $false
    }

    foreach ($file in (Get-ChildItem -LiteralPath $DatabasesDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $j = Read-JsonFile -Path $file.FullName
            if ($null -ne $j -and [string]$j.db_source_id -eq $Id) {
                Write-Host ''
                Write-Host "ОШИБКА: DB_SOURCE_ID '$Id' уже используется:" -ForegroundColor Red
                Write-Host $file.FullName -ForegroundColor Yellow
                return $false
            }
        }
        catch {
            # Пропускаем поврежденный/невалидный JSON и продолжаем проверку.
        }
    }

    return $true
}

function Terminal-Setup {
    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host ' НАСТРОЙКА ОБЩИХ ПАРАМЕТРОВ'
    Write-Host '------------------------------------------------------------'
    Write-Host ''

    Write-Host 'RDP-диск:'
    Write-Host "[$RdpDrive]"
    $value = Read-Host 'Новый RDP-диск (Enter - оставить текущее)'
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $RdpDrive = $value
    }

    if (-not (Test-Path -LiteralPath ($RdpDrive + '\'))) {
        Write-Host ''
        Write-Host "ВНИМАНИЕ: путь '$RdpDrive' сейчас недоступен." -ForegroundColor Yellow
        Write-Host 'Проверьте, что RDP-диск подключен.'
        Write-Host ''
        $confirm = Read-Host 'Сохранить этот путь всё равно? [Y/N]'
        if ($confirm -notmatch '^[Yy]$') { return }
    }

    Write-Host ''
    Write-Host 'Путь MCP на RDP-диске:'
    Write-Host "[$McpPath]"
    $value = Read-Host 'Новый путь (Enter - оставить текущее)'
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $McpPath = $value
    }

    Save-Common

    Write-Host ''
    Write-Host 'Рабочий каталог терминала:'
    Write-Host "[$McpWork]"
    $value = Read-Host 'Новый путь (Enter - оставить текущее)'
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $McpWork = $value
    }

    Write-Host ''
    Write-Host 'Путь к 1cv8.exe:'
    Write-Host "[$OnecBin]"
    $value = Read-Host 'Новый путь (Enter - оставить текущее)'
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        $OnecBin = $value
    }

    if (-not (Test-Path -LiteralPath ($McpWork + '\'))) {
        Write-Host ''
        $create = Read-Host 'Рабочего каталога нет. Создать его? [Y/N]'
        if ($create -match '^[Yy]$') {
            try {
                New-Item -ItemType Directory -Force -Path $McpWork | Out-Null
            }
            catch {
                Write-Host "Не удалось создать '$McpWork'." -ForegroundColor Red
                return
            }
        }
    }

    if (-not (Test-Path -LiteralPath ($McpWork + '\'))) {
        Write-Host "Рабочий каталог не найден: '$McpWork'" -ForegroundColor Red
        return
    }

    if (-not (Test-Path -LiteralPath $OnecBin -PathType Leaf)) {
        Write-Host ''
        Write-Host 'ВНИМАНИЕ: 1cv8.exe не найден:' -ForegroundColor Yellow
        Write-Host $OnecBin
    }

    Save-Terminal

    Write-Host ''
    Write-Host 'Терминал сохранён:'
    Write-Host $TerminalJson
}

function Database-Setup {
    Write-Host ''
    Write-Host '------------------------------------------------------------'
    Write-Host ' ДОБАВЛЕНИЕ БАЗЫ'
    Write-Host '------------------------------------------------------------'
    Write-Host ''

    New-Item -ItemType Directory -Force -Path $DatabaseDir | Out-Null

    $dbSourceId = Read-Host 'DB_SOURCE_ID'
    if ([string]::IsNullOrWhiteSpace($dbSourceId)) {
        Write-Host 'DB_SOURCE_ID не может быть пустым.' -ForegroundColor Red
        return
    }

    if (-not (Validate-SourceId -Id $dbSourceId)) {
        return
    }

    $dbServer = Read-Host 'Сервер 1С'
    if ([string]::IsNullOrWhiteSpace($dbServer)) {
        Write-Host 'Сервер 1С не может быть пустым.' -ForegroundColor Red
        return
    }

    $dbDatabase = Read-Host 'Имя базы'
    if ([string]::IsNullOrWhiteSpace($dbDatabase)) {
        Write-Host 'Имя базы не может быть пустым.' -ForegroundColor Red
        return
    }

    $dbUser = Read-Host 'Пользователь 1С'
    if ([string]::IsNullOrWhiteSpace($dbUser)) {
        Write-Host 'Пользователь не может быть пустым.' -ForegroundColor Red
        return
    }

    $dbPassword = Read-Host 'Пароль 1С'

    $extensions = [System.Collections.Generic.List[string]]::new()
    $index = 1

    while ($true) {
        $extension = Read-Host "Имя расширения $index"

        if ([string]::IsNullOrWhiteSpace($extension)) {
            if ($index -eq 1) {
                Write-Host 'Первое расширение должно быть указано.' -ForegroundColor Red
                continue
            }
            break
        }

        [void]$extensions.Add($extension)

        Write-Host ''
        $continue = Read-Host 'Продолжить? (N - ввести имя следующего расширения, Enter - закончить)'
        if ($continue -notmatch '^[Nn]$') {
            break
        }

        $index++
    }

    $dbJson = Join-Path $DatabaseDir "$dbSourceId.json"

    $obj = [ordered]@{
        db_source_id = $dbSourceId
        db_server     = $dbServer
        db_database   = $dbDatabase
        db_user       = $dbUser
        db_password   = $dbPassword
        extensions    = @($extensions)
    }

    Save-JsonFile -Path $dbJson -Object $obj

    Write-Host ''
    Write-Host 'База сохранена:'
    Write-Host $dbJson
    Write-Host ''

    $addMore = Read-Host 'Добавить ещё одну базу на этом терминале? [Y/N]'
    if ($addMore -match '^[Yy]$') {
        Database-Setup
    }
}

Load-Common
Load-Terminal

while ($true) {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' MCP - НАСТРОЙКА'
    Write-Host '============================================================'
    Write-Host ''
    Write-Host "Компьютер: $Computer"
    Write-Host "Пользователь: $UserName"
    Write-Host ''
    Write-Host '[1] Настроить терминал'
    Write-Host '[2] Добавить базу'
    Write-Host '[3] Выход'
    Write-Host ''

    $choice = Read-Host 'Выберите действие [1-3]'

    switch ($choice) {
        '1' { Terminal-Setup }
        '2' { Database-Setup }
        '3' {
            Write-Host ''
            Write-Host 'Настройка завершена.'
            exit 0
        }
        default {
            Write-Host 'Неверный выбор.' -ForegroundColor Yellow
        }
    }
}
