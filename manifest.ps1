#requires -version 5.1
<#
.SYNOPSIS
    Создаёт манифест файлов указанного каталога.

.DESCRIPTION
    Собирает сведения о всех файлах каталога и сохраняет их в JSON.
    По умолчанию хэши не вычисляются.
    Параметр -WithMD5 вычисляет MD5.
    Параметр -WithHash вычисляет SHA-256.

.PARAMETER Path
    Каталог, для которого создаётся манифест.

.PARAMETER OutputPath
    Полный путь к JSON-файлу манифеста.

.PARAMETER WithMD5
    Вычислять MD5 для каждого файла.

.PARAMETER WithHash
    Вычислять SHA-256 для каждого файла.

.EXAMPLE
    .\manifest.ps1 -Path 'F:\Users\LatypovRR\MCP\dump\AKK\DO_AKK' -OutputPath 'F:\Users\LatypovRR\MCP\dump\AKK\DO_AKK\manifest-md5.json' -WithMD5

.EXAMPLE
    .\manifest.ps1 -Path 'F:\Users\LatypovRR\MCP\dump\AKK\DO_AKK' -OutputPath 'F:\Users\LatypovRR\MCP\dump\AKK\DO_AKK\manifest-sha256.json' -WithHash
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$WithMD5,

    [Parameter(Mandatory = $false)]
    [switch]$WithHash
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptStart = Get-Date

Write-Host ''
Write-Host '============================================================'
Write-Host 'DumpFlow1c manifest'
Write-Host '============================================================'
Write-Host ('Старт:      {0}' -f $scriptStart.ToString('yyyy-MM-dd HH:mm:ss.fff'))
Write-Host ('Каталог:    {0}' -f $Path)
Write-Host ('MD5:        {0}' -f $(if ($WithMD5) { 'ДА' } else { 'НЕТ' }))
Write-Host ('SHA-256:    {0}' -f $(if ($WithHash) { 'ДА' } else { 'НЕТ' }))
Write-Host ''

if ($WithMD5 -and $WithHash) {
    Write-Host 'ОШИБКА: одновременно указывать -WithMD5 и -WithHash нельзя.'
    exit 1
}

try {
    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        throw "Указанный путь не является каталогом: $resolvedPath"
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $directoryInfo = New-Object System.IO.DirectoryInfo($resolvedPath)
        $timestamp = $scriptStart.ToString('yyyy-MM-dd_HHmmss')
        $OutputPath = Join-Path $directoryInfo.Parent.FullName ($directoryInfo.Name + '_manifest_' + $timestamp + '.json')
    }
    else {
        $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    }

    Write-Host '[1/4] Поиск файлов...'

    $files = @(Get-ChildItem -LiteralPath $resolvedPath -File -Recurse -Force -ErrorAction Stop)

    $totalFiles = $files.Count
    $totalBytes = [int64]0

    foreach ($file in $files) {
        $totalBytes += $file.Length
    }

    Write-Host ('      Файлов:  {0:N0}' -f $totalFiles)
    Write-Host ('      Размер:  {0:N0} байт' -f $totalBytes)
    Write-Host ''

    Write-Host '[2/4] Формирование данных...'

    $fileRecords = New-Object System.Collections.Generic.List[object]
    $processedBytes = [int64]0
    $index = 0

    foreach ($file in $files) {
        $index++

        $record = [ordered]@{
            FullPath      = $file.FullName
            Size          = [int64]$file.Length
            CreationTime  = $file.CreationTime.ToString('o')
            LastWriteTime = $file.LastWriteTime.ToString('o')
        }

        if ($WithMD5) {
            $record['MD5'] = (Get-FileHash -LiteralPath $file.FullName -Algorithm MD5 -ErrorAction Stop).Hash
        }

        if ($WithHash) {
            $record['SHA256'] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        }

        $fileRecords.Add([PSCustomObject]$record)

        $processedBytes += [int64]$file.Length

        if (($index -eq 1) -or ($index -eq $totalFiles) -or (($index % 100) -eq 0)) {
            $percent = 100
            if ($totalFiles -gt 0) {
                $percent = [int][Math]::Floor(($index * 100.0) / $totalFiles)
            }

            $bytesPercent = 100
            if ($totalBytes -gt 0) {
                $bytesPercent = [int][Math]::Floor(($processedBytes * 100.0) / $totalBytes)
            }

            $progressStatus = 'Файлы: {0:N0}/{1:N0}; данные: {2}%' -f $index, $totalFiles, $bytesPercent
            Write-Progress -Activity 'Формирование манифеста' -Status $progressStatus -PercentComplete $percent
        }
    }

    Write-Progress -Activity 'Формирование манифеста' -Completed

    Write-Host ''
    Write-Host '[3/4] Запись JSON...'

    $scriptEnd = Get-Date
    $duration = $scriptEnd - $scriptStart

    $hashAlgorithm = $null
    if ($WithMD5) {
        $hashAlgorithm = 'MD5'
    }
    elseif ($WithHash) {
        $hashAlgorithm = 'SHA256'
    }

    $manifest = [ordered]@{
        ManifestVersion = 1
        CreatedAt       = $scriptStart.ToString('o')
        CompletedAt     = $scriptEnd.ToString('o')
        DurationSeconds = [Math]::Round($duration.TotalSeconds, 3)
        SourcePath      = $resolvedPath
        HashAlgorithm   = $hashAlgorithm
        FileCount       = $totalFiles
        TotalSize       = $totalBytes
        Files           = $fileRecords
    }

    $json = $manifest | ConvertTo-Json -Depth 5

    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText(
        $OutputPath,
        $json,
        (New-Object System.Text.UTF8Encoding($true))
    )

    Write-Host '[4/4] Готово.'
    Write-Host ''
    Write-Host '============================================================'
    Write-Host ('Файлов:     {0:N0}' -f $totalFiles)
    Write-Host ('Размер:     {0:N0} байт' -f $totalBytes)
    Write-Host ('MD5:        {0}' -f $(if ($WithMD5) { 'ДА' } else { 'НЕТ' }))
    Write-Host ('SHA-256:    {0}' -f $(if ($WithHash) { 'ДА' } else { 'НЕТ' }))
    Write-Host ('Манифест:   {0}' -f $OutputPath)
    Write-Host ('Окончание:  {0}' -f $scriptEnd.ToString('yyyy-MM-dd HH:mm:ss.fff'))
    Write-Host ('Время:      {0}' -f $duration.ToString('hh\:mm\:ss\.fff'))
    Write-Host '============================================================'
    Write-Host ''
}
catch {
    Write-Progress -Activity 'Формирование манифеста' -Completed -ErrorAction SilentlyContinue

    $scriptEnd = Get-Date
    $duration = $scriptEnd - $scriptStart

    Write-Host ''
    Write-Host 'ОШИБКА:'
    Write-Host $_.Exception.Message
    Write-Host ('Окончание:  {0}' -f $scriptEnd.ToString('yyyy-MM-dd HH:mm:ss.fff'))
    Write-Host ('Время:      {0}' -f $duration.ToString('hh\:mm\:ss\.fff'))
    Write-Host ''

    exit 1
}
