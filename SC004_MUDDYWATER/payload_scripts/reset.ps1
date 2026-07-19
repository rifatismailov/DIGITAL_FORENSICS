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

# Читаємо e.brown credentials ДО видалення upd_logs (інакше файл буде вже стертий)
$WS2_USER = "e.brown"
$WS2_PASS = "W!lDc@T22"  # fallback — змінити якщо пароль інший
$creds_csv = Get-ChildItem "$LOG_DIR\creds" -Filter "*.csv" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($creds_csv) {
    $cred_line = Get-Content $creds_csv.FullName |
        Where-Object { $_ -notmatch "^user" -and $_ -match "e\.brown" } | Select-Object -First 1
    if ($cred_line) {
        $cp = $cred_line.Split(','); $WS2_USER = $cp[0].Trim(); $WS2_PASS = $cp[1].Trim()
    }
}

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

# ── Persistent копія скриптів (current user + k.johnson + e.brown) ───────────

$persist_dirs = @(
    $PERSIST_DIR,
    "C:\Users\k.johnson\AppData\Roaming\Microsoft\WinUpd",
    "C:\Users\e.brown\AppData\Roaming\Microsoft\WinUpd"
)
foreach ($dir in $persist_dirs) {
    if (Test-Path $dir) {
        try {
            [System.IO.Directory]::Delete($dir, $true)
            Write-Host "  Deleted: $dir" -ForegroundColor DarkGray
        } catch {
            cmd /c "rmdir /s /q `"$dir`""
            Write-Host "  Deleted (fallback): $dir" -ForegroundColor DarkGray
        }
    }
}

# ── Startup папка (block6 копіює сюди на цільовій машині) ────────────────────

$startup_allusers = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
$startup_user     = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$startup_kjohnson = "C:\Users\k.johnson\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
$startup_ebrown   = "C:\Users\e.brown\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"

$startup_files = @(
    "implant.bat","implant.ps1",
    "block1_persist.ps1","block2_discovery.ps1","block3_scan.ps1",
    "block4_staging.ps1","block5_exfil.ps1","block6_lateral.ps1",
    "block7_fileserver.ps1","config.ps1","WinSecUpdate.bat"
)

# Grant admin access to other users' startup folders before deletion
foreach ($otherStartup in @($startup_allusers, $startup_kjohnson, $startup_ebrown)) {
    if (Test-Path $otherStartup) {
        cmd /c "takeown /f `"$otherStartup`" /r /d y >nul 2>&1"
        cmd /c "icacls `"$otherStartup`" /grant administrators:F /t >nul 2>&1"
    }
}

foreach ($startup in @($startup_allusers, $startup_user, $startup_kjohnson, $startup_ebrown)) {
    $startup_files | ForEach-Object {
        $f = Join-Path $startup $_
        if (Test-Path $f) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
            if (Test-Path $f) {
                cmd /c "del /f /q `"$f`"" 2>$null
            }
            if (-not (Test-Path $f)) {
                Write-Host "  Deleted from Startup: $_" -ForegroundColor DarkGray
            } else {
                Write-Host "  ACCESS DENIED (run reset.ps1 as Administrator): $f" -ForegroundColor Red
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

    # Registry Run keys (HKCU current user + HKLM)
    $reg_hkcu = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $reg_hklm = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    $run_names = @("SecurityHealthUpdater", "WinUpdateSvc", "WinSecUpdate")
    $run_names | ForEach-Object {
        foreach ($reg in @($reg_hkcu, $reg_hklm)) {
            if (Get-ItemProperty $reg -Name $_ -ErrorAction SilentlyContinue) {
                Remove-ItemProperty $reg -Name $_ -Force -ErrorAction SilentlyContinue
                Write-Host "  Deleted RunKey [$($reg -replace '.*\\Run','')]: $_" -ForegroundColor DarkGray
            }
        }
    }

    # Registry Run keys under k.johnson and e.brown (load hive if user not logged in)
    foreach ($otherUser in @("k.johnson", "e.brown")) {
        $ntuser = "C:\Users\$otherUser\NTUSER.DAT"
        $hiveKey = "HKU\reset_$otherUser"
        $hivePS  = "Registry::HKU\reset_$otherUser"
        $loaded  = $false

        # Try loading the hive (only works if user is NOT currently logged in)
        if (Test-Path $ntuser) {
            $out = reg load $hiveKey $ntuser 2>&1
            if ($LASTEXITCODE -eq 0) { $loaded = $true }
        }

        # If user IS logged in, their hive is already under HKU\<SID>
        $sid = (Get-LocalUser -Name $otherUser -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty SID).Value
        if (-not $loaded -and $sid -and (Test-Path "Registry::HKU\$sid")) {
            $hivePS = "Registry::HKU\$sid"
            $loaded = $true
        }

        if ($loaded) {
            $runPath = "$hivePS\Software\Microsoft\Windows\CurrentVersion\Run"
            $run_names | ForEach-Object {
                if (Get-ItemProperty $runPath -Name $_ -ErrorAction SilentlyContinue) {
                    Remove-ItemProperty $runPath -Name $_ -Force -ErrorAction SilentlyContinue
                    Write-Host "  Deleted RunKey [$otherUser HKCU]: $_" -ForegroundColor DarkGray
                }
            }
            if ($hivePS -like "*reset_*") {
                [gc]::Collect()
                reg unload $hiveKey 2>&1 | Out-Null
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
Remove-Item "$env:TEMP\impl.ps1"         -Force -ErrorAction SilentlyContinue

# k.johnson temp (WS-1)
$kj_temp = "C:\Users\k.johnson\AppData\Local\Temp"
Remove-Item "$kj_temp\implant.rar" -Force   -ErrorAction SilentlyContinue
Remove-Item "$kj_temp\impl.ps1"    -Force   -ErrorAction SilentlyContinue
Remove-Item "$kj_temp\wupd"        -Recurse -Force -ErrorAction SilentlyContinue

# e.brown temp (WS-2)
$eb_temp = "C:\Users\e.brown\AppData\Local\Temp"
Remove-Item "$eb_temp\implant.rar" -Force   -ErrorAction SilentlyContinue
Remove-Item "$eb_temp\impl.ps1"    -Force   -ErrorAction SilentlyContinue
Remove-Item "$eb_temp\wupd"        -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "  Cleaned: implant temp files (current user + k.johnson + e.brown)" -ForegroundColor DarkGray

# ── Remote WS-2: повне очищення через SMB з кредами e.brown ──────────────────

$currentHost = $env:COMPUTERNAME
$ws2_targets = @("192.168.210.102")

foreach ($ws2 in $ws2_targets) {
    $ws2_hostname = try { [System.Net.Dns]::GetHostEntry($ws2).HostName.Split('.')[0] } catch { "" }
    if ($currentHost -eq $ws2_hostname -or $currentHost -eq "WS-2") {
        Write-Host "  Running ON WS-2 — skipping remote SMB cleanup" -ForegroundColor DarkGray
        continue
    }

    # Підключаємось до WS-2 з кредами (зчитані на початку скрипту)
    $share = "\\$ws2\C$"
    net use $share /delete 2>$null | Out-Null
    $connected = $false

    foreach ($fmt in @("GOV.LOCAL\$WS2_USER", "$ws2\$WS2_USER", $WS2_USER)) {
        $r = net use $share /user:$fmt $WS2_PASS 2>&1
        if ($LASTEXITCODE -eq 0) {
            $connected = $true
            Write-Host "  WS-2 SMB: підключено як $fmt" -ForegroundColor DarkGray
            break
        }
    }
    if (-not $connected) {
        $r = net use $share 2>&1
        if ($LASTEXITCODE -eq 0) { $connected = $true }
    }

    if ($connected) {
        # wsu.lock
        Remove-Item "\\$ws2\C$\Windows\Temp\wsu.lock" -Force -ErrorAction SilentlyContinue

        # Скрипти в Windows\Temp (block6 кладе сюди)
        Get-ChildItem "\\$ws2\C$\Windows\Temp" -Filter "*.ps1" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem "\\$ws2\C$\Windows\Temp" -Filter "*.bat" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        # All-Users Startup
        $ws2_all_startup = "\\$ws2\C$\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
        $startup_files | ForEach-Object {
            Remove-Item "$ws2_all_startup\$_" -Force -ErrorAction SilentlyContinue
        }

        # Per-user Startup + WinUpd persist (всі профілі)
        Get-ChildItem "\\$ws2\C$\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
            ForEach-Object {
                $uname = $_.Name
                $user_startup = "\\$ws2\C$\Users\$uname\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
                $startup_files | ForEach-Object {
                    Remove-Item "$user_startup\$_" -Force -ErrorAction SilentlyContinue
                }
                $winupd = "\\$ws2\C$\Users\$uname\AppData\Roaming\Microsoft\WinUpd"
                if (Test-Path $winupd) {
                    Remove-Item $winupd -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Host "  Deleted WS-2 WinUpd: $uname" -ForegroundColor DarkGray
                }
            }

        # upd_logs (якщо block1 вже запускався на WS-2)
        if (Test-Path "\\$ws2\C$\ProgramData\upd_logs") {
            Remove-Item "\\$ws2\C$\ProgramData\upd_logs" -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Deleted WS-2 upd_logs" -ForegroundColor DarkGray
        }

        # ZIP staging
        Get-ChildItem "\\$ws2\C$\ProgramData\WinUpd_*.zip" -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        Write-Host "  WS-2 ($ws2): повне очищення виконано" -ForegroundColor DarkGray
        net use $share /delete 2>$null | Out-Null
    } else {
        Write-Host "  WS-2 ($ws2) недоступний по SMB — зайди на WS-2 і запусти reset.ps1 вручну" -ForegroundColor Yellow
    }
}

# ── File Server (FILES-01): артефакти block7 ─────────────────────────────────

# Знаходимо підключені шари (так само як B7)
$b7_shares = [System.Collections.Generic.List[string]]::new()
net use 2>&1 | ForEach-Object {
    if ($_ -match 'OK\s+\S+\s+(\\\\[^\s]+)') { $b7_shares.Add($Matches[1]) }
}
if (Test-Path "HKCU:\Network") {
    Get-ChildItem "HKCU:\Network" -ErrorAction SilentlyContinue | ForEach-Object {
        $remote = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RemotePath
        if ($remote -and $b7_shares -notcontains $remote) { $b7_shares.Add($remote) }
    }
}

foreach ($share in $b7_shares) {
    if (-not (Test-Path $share)) { continue }

    # .winsec маркер
    Remove-Item "$share\.winsec" -Force -ErrorAction SilentlyContinue

    # Macro-injected файли
    Get-ChildItem $share -Filter "*.docm" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $share -Filter "*.xlsm" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # VBS fallback
    Remove-Item "$share\WindowsSecurityUpdate.vbs" -Force -ErrorAction SilentlyContinue

    Write-Host "  Cleaned file server share: $share" -ForegroundColor DarkGray
}

# AccessVBOM Registry (block7 виставляє 1, повертаємо 0)
Get-ChildItem "HKCU:\Software\Microsoft\Office" -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($app in @("Word", "Excel")) {
        $path = "HKCU:\Software\Microsoft\Office\$($_.PSChildName)\$app\Security"
        if (Test-Path $path) {
            Set-ItemProperty -Path $path -Name "AccessVBOM" -Value 0 -Force -ErrorAction SilentlyContinue
        }
    }
}
Write-Host "  Reset: Office AccessVBOM → 0" -ForegroundColor DarkGray

# ── Підсумок ──────────────────────────────────────────────────────────────────

Write-Host "`nГотово. Тепер можна запускати block1 знову." -ForegroundColor Green
Write-Host "Залишилось у upd_logs:" -ForegroundColor Cyan
if (Test-Path $LOG_DIR) {
    Get-ChildItem $LOG_DIR -Force | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
} else {
    Write-Host "  (порожньо)" -ForegroundColor DarkGray
}
