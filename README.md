# DumpFlow1c
# DumpFlow1c: v1.0.1 — 2026-10-03 06:43


PowerShell-пайплайн передачи dump конфигураций 1С с Windows-терминала на RDP-клиент.

Текущая граница:

~~~text
1С → permanent dump → manifest → changes → 7z delta → RDP MCP/archive
~~~

Проект задаётся в config/common.json:

~~~json
{
    "project_name": "AKK",
    "rdp_drive": "\\\\tsclient\\L",
    "mcp_path": "!work\\RAU_IT\\MCP"
}
~~~

Основной запуск:

~~~powershell
.\update.ps1
~~~

Этапы:

1. prepare.ps1 — проверка окружения и создание каталогов проекта.
2. dump_config.ps1 — постоянная выгрузка 1С в dump/<PROJECT>/<DB>.
3. manifest.ps1 — полный MD5-снимок текущего dump.
4. compare_manifests.ps1 — определение ADDED/MODIFIED/DELETED.
5. pack.ps1 — упаковка только ADDED/MODIFIED.
6. upload.ps1 — передача .7z, .sha256, manifest, changes на RDP и подтверждение доставки.
7. control_upload.ps1 — визуальный контроль комплекта на RDP-клиенте.

История версий хранится в:

~~~text
<PROJECT>/metadata/<DB>/
├── <DB>_<snapshot>_manifest.json
├── <DB>_<snapshot>_changes.json
└── state.json
~~~

Передача на Ubuntu/leoVM проектируется отдельным этапом.
