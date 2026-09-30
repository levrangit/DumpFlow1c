#Requires -Version 5.1
<#
Создаёт полный manifest постоянного dump-каталога.
MD5 используется как быстрый идентификатор содержимого файлов.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$ProjectName,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $false)]
    [string]$SnapshotId = (Get-Date).ToString('yyyyMMdd_HHmmss'),

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [switch]$WithMD5
)

$ErrorActionPreference = 'Stop'

if (-not $WithMD5) {
    throw 'Для транспортного manifest необходимо указать -WithMD5.'
}
if ($ProjectName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Некорректный ProjectName: $ProjectName" }
if ($DatabaseName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw "Некорректный DatabaseName: $DatabaseName" }

$started = Get-Date
$resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) { throw "Не каталог: $resolvedPath" }

$files = @(Get-ChildItem -LiteralPath $resolvedPath -Recurse -File -Force -ErrorAction Stop | Sort-Object FullName)
if ($files.Count -eq 0) { throw "Dump пуст: $resolvedPath" }

$fileRecords = New-Object System.Collections.Generic.List[object]
$totalBytes = [int64]0
$index = 0

foreach ($file in $files) {
    $index++
    $relative = $file.FullName.Substring($resolvedPath.Length).TrimStart('\','/')
    $relative = $relative -replace '\','/'

    $record = [ordered]@{
        RelativePath = $relative
        SizeBytes    = [int64]$file.Length
        MD5          = (Get-FileHash -LiteralPath $file.FullName -Algorithm MD5 -ErrorAction Stop).Hash.ToUpperInvariant()
    }
    $fileRecords.Add([PSCustomObject]$record)
    $totalBytes += [int64]$file.Length

    if (($index -eq 1) -or ($index -eq $files.Count) -or (($index % 100) -eq 0)) {
        Write-Progress -Activity 'Формирование manifest' -Status "$index/$($files.Count)" -PercentComplete ([int](($index * 100.0) / $files.Count))
    }
}
Write-Progress -Activity 'Формирование manifest' -Completed

$completed = Get-Date
$manifest = [ordered]@{
    ManifestVersion = 1
    Project         = $ProjectName
    Database        = $DatabaseName
    SnapshotId      = $SnapshotId
    CreatedAt       = $started.ToString('o')
    CompletedAt     = $completed.ToString('o')
    HashAlgorithm   = 'MD5'
    DumpPath        = "dump/$ProjectName/$DatabaseName"
    FileCount       = $files.Count
    TotalSizeBytes  = $totalBytes
    Files           = $fileRecords
}

$outputDirectory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host "MANIFEST: $OutputPath"
Write-Host "Проект: $ProjectName"
Write-Host "База: $DatabaseName"
Write-Host "SnapshotId: $SnapshotId"
Write-Host ("Файлов: {0:N0}" -f $files.Count)
Write-Host ("Размер: {0:N0} байт" -f $totalBytes)
exit 0
