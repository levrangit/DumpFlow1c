# DumpFlow1c — архитектура передачи 1С dump с терминала на RDP-клиент

Дата фиксации: 2026-09-30

## Назначение

DumpFlow1c формирует на Windows-терминале постоянный dump 1С, определяет изменения между текущим состоянием и последней успешно доставленной версией, упаковывает только изменившиеся файлы и передаёт на RDP-клиент транспортный комплект:

- .7z;
- .7z.sha256;
- <DB>_<snapshot>_manifest.json;
- <DB>_<snapshot>_changes.json.

Этап RDP-клиент → Ubuntu/leoVM в эту схему пока не входит.

## Главная схема

~~~
update.ps1
    │
    ├── prepare.ps1
    ├── dump_config.ps1
    ├── manifest.ps1
    ├── compare_manifests.ps1
    ├── pack.ps1
    └── upload.ps1
~~~

## Проект

Имя проекта является настройкой common.json:

~~~json
{
    "project_name": "AKK",
    "rdp_drive": "\\\\tsclient\\L",
    "mcp_path": "!work\\RAU_IT\\MCP"
}
~~~

Настройка выполняется через setup.ps1. prepare.ps1 обязательно проверяет project_name.

Проект является частью пути dump и metadata:

~~~
<mcp_work>/
├── dump/
│   └── AKK/
│       ├── DO_AKK/
│       │   ├── config/
│       │   └── extensions/
│       └── ERP_AKK/
├── metadata/
│   └── AKK/
│       ├── DO_AKK/
│       └── ERP_AKK/
├── archive/
└── logs/
~~~

## Постоянный dump

Каталог:

~~~
dump/<PROJECT>/<DB_SOURCE_ID>/
~~~

не заменяется staging-каталогом при каждом запуске.

dump_config.ps1 выгружает 1С непосредственно в постоянные:

~~~
dump/<PROJECT>/<DB>/config/
dump/<PROJECT>/<DB>/extensions/<EXTENSION>/
~~~

Это сделано для сохранения состояния ConfigDumpInfo.xml и возможности использовать механизм инкрементальной выгрузки 1С.

## Metadata

Для каждой базы:

~~~
metadata/<PROJECT>/<DB>/
├── <DB>_<snapshot>_manifest.json
├── <DB>_<snapshot>_changes.json
└── state.json
~~~

История manifest/changes сохраняется. Подкаталоги версий не используются.

## Manifest

<DB>_<snapshot>_manifest.json — полный снимок текущего dump.

В Files используется только RelativePath. Абсолютные Windows-пути в manifest не записываются.

~~~json
{
    "ManifestVersion": 1,
    "Project": "AKK",
    "Database": "DO_AKK",
    "SnapshotId": "20260930_180000",
    "HashAlgorithm": "MD5",
    "DumpPath": "dump/AKK/DO_AKK",
    "FileCount": 4,
    "TotalSizeBytes": 48128,
    "Files": [
        {
            "RelativePath": "config/Documents/Заказ.xml",
            "SizeBytes": 15320,
            "MD5": "A1B2..."
        }
    ]
}
~~~

## Changes

<DB>_<snapshot>_changes.json — delta между текущим manifest и последним успешно доставленным manifest.

Возможные действия:

- ADDED;
- MODIFIED;
- DELETED.

UNCHANGED в массив Files не записывается, только учитывается в UnchangedCount.

Правила упаковки:

~~~
ADDED     -> входит в 7z
MODIFIED  -> входит в 7z
DELETED   -> в 7z не входит
~~~

На первом запуске state.json отсутствует, поэтому все файлы считаются ADDED.

## State

state.json хранит только указатель на последнюю успешно доставленную версию:

~~~json
{
    "Version": 1,
    "Project": "AKK",
    "Database": "DO_AKK",
    "LastSuccessfulSnapshotId": "20260930_180000",
    "LastSuccessfulManifest": "DO_AKK_20260930_180000_manifest.json",
    "LastSuccessfulChanges": "DO_AKK_20260930_180000_changes.json",
    "LastSuccessfulAt": "2026-09-30T18:02:41+05:00"
}
~~~

state.json обновляется только после проверки файлов на RDP-диске самим upload.ps1.

## Архив

pack.ps1 читает последний <DB>_*_changes.json каждой базы.

Для ADDED и MODIFIED создаётся временный список относительных путей, после чего portable 7za.exe создаёт:

~~~
archive/<DB>_<snapshot>.7z
archive/<DB>_<snapshot>.7z.sha256
~~~

В архиве сохраняются относительные пути относительно dump/<PROJECT>/<DB>/.

В archive/ также копируются соответствующие manifest и changes. Таким образом archive содержит готовый транспортный комплект версии.

## Control upload

Старое имя control заменено на control_upload.

На RDP-клиенте:

~~~
MCP/
├── archive/
└── control_upload/
    └── control_upload.json
~~~

upload.ps1 создаёт control_upload.json до передачи.

Он содержит ожидаемый комплект для каждой базы: Manifest, Changes, Archive и ArchiveChecksum.

control_upload.ps1 на RDP-клиенте показывает состояние каждого из четырёх файлов и проверяет наличие, размер, SHA-256 архива и MD5 manifest/changes.

## Upload

upload.ps1 передаёт ровно четыре файла на каждую версию:

~~~
<DB>_<snapshot>.7z
<DB>_<snapshot>.7z.sha256
<DB>_<snapshot>_manifest.json
<DB>_<snapshot>_changes.json
~~~

Передача выполняется через rclone copyto.

После передачи upload.ps1 дополнительно проверяет файлы непосредственно через RDP mapped drive. Только после успешной проверки он обновляет state.json.

## Граница системы

~~~
1С
 ↓
permanent dump
 ↓
manifest
 ↓
changes
 ↓
7z delta
 ↓
SHA-256
 ↓
control_upload
 ↓
rclone
 ↓
RDP MCP/archive
~~~

RDP → Ubuntu/leoVM пока не реализуется.

## Файлы проекта

~~~
prepare.ps1
dump_config.ps1
manifest.ps1
compare_manifests.ps1
pack.ps1
upload.ps1
control_upload.ps1
update.ps1
setup.ps1
~~~

control.ps1 больше не используется.
