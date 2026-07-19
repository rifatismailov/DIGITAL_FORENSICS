# =============================================================================
# check_artifacts.ps1 — Read-only scan for all MUDDYWATER artifacts
# Run on WS-1 or WS-2 to see what needs cleaning before reset
# =============================================================================

$ErrorActionPreference = "SilentlyContinue"

$found  = 0
$clean  = 0

function Check-Path {
    param([string]$Path, [string]$Label)
    if (Test-Path $Path) {
        $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
        if ($item -is [System.IO.DirectoryInfo]) {
            $count = (Get-ChildItem $Path -Force -ErrorAction SilentlyContinue).Count
            Write-Host "  [FOUND] $Label ($count items)" -ForegroundColor Red
        } else {
            $size = $item.Length
            Write-Host "  [FOUND] $Label ($size bytes)" -ForegroundColor Red
        }
        $script:found++
    } else {
        Write-Host "  [clean] $Label" -ForegroundColor DarkGreen
        $script:clean++
    }
}

Write-Host "`n=== MUDDYWATER Artifact Check: $env:COMPUTERNAME ===" -ForegroundColor Cyan

# ── Logs & Staging ────────────────────────────────────────────────────────────
Write-Host "`n[Logs & Staging]" -ForegroundColor Yellow
Check-Path "C:\ProgramData\upd_logs"      "upd_logs dir"
Check-Path "C:\ProgramData\WinUpd_*.zip"  "WinUpd staging ZIPs"
Get-ChildItem "C:\ProgramData\WinUpd_*.zip" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "    -> $($_.FullName)" -ForegroundColor DarkRed
}

# ── Persistence dir ───────────────────────────────────────────────────────────
Write-Host "`n[Persistence Dir]" -ForegroundColor Yellow
Check-Path "$env:APPDATA\Microsoft\WinUpd" "WinUpd persist dir"

# ── Startup folders ───────────────────────────────────────────────────────────
Write-Host "`n[Startup Folders]" -ForegroundColor Yellow

$startup_files = @(
    "implant.bat","implant.ps1","WinSecUpdate.bat",
    "block1_persist.ps1","block2_discovery.ps1","block3_scan.ps1",
    "block4_staging.ps1","block5_exfil.ps1","block6_lateral.ps1",
    "block7_fileserver.ps1","config.ps1"
)

$startups = @{
    "AllUsers"  = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
    "Current"   = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    "k.johnson" = "C:\Users\k.johnson\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    "e.brown"   = "C:\Users\e.brown\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
}

foreach ($label in $startups.Keys) {
    $dir = $startups[$label]
    foreach ($f in $startup_files) {
        Check-Path "$dir\$f" "Startup\$label\$f"
    }
}

# ── Scheduled Tasks ───────────────────────────────────────────────────────────
Write-Host "`n[Scheduled Tasks]" -ForegroundColor Yellow
@("WindowsUpdateCheck", "WinUpdateSvc") | ForEach-Object {
    $task = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host "  [FOUND] ScheduledTask: $_" -ForegroundColor Red
        $script:found++
    } else {
        Write-Host "  [clean] ScheduledTask: $_" -ForegroundColor DarkGreen
        $script:clean++
    }
}

# ── Registry Run Keys ─────────────────────────────────────────────────────────
Write-Host "`n[Registry Run Keys]" -ForegroundColor Yellow
$reg_paths = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
)
@("SecurityHealthUpdater", "WinUpdateSvc", "WinSecUpdate") | ForEach-Object {
    $name = $_
    foreach ($reg in $reg_paths) {
        $hive = if ($reg -match "HKCU") { "HKCU" } else { "HKLM" }
        if (Get-ItemProperty $reg -Name $name -ErrorAction SilentlyContinue) {
            Write-Host "  [FOUND] RunKey [$hive]: $name" -ForegroundColor Red
            $script:found++
        } else {
            Write-Host "  [clean] RunKey [$hive]: $name" -ForegroundColor DarkGreen
            $script:clean++
        }
    }
}

# ── Windows\Temp ──────────────────────────────────────────────────────────────
Write-Host "`n[Windows\Temp]" -ForegroundColor Yellow
Check-Path "C:\Windows\Temp\wsu.lock" "wsu.lock"
Get-ChildItem "C:\Windows\Temp\*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  [FOUND] C:\Windows\Temp\$($_.Name)" -ForegroundColor Red
    $script:found++
}

# ── Implant Temp Files ────────────────────────────────────────────────────────
Write-Host "`n[Implant Temp Files]" -ForegroundColor Yellow
$temp_users = @{
    "Current"   = $env:TEMP
    "k.johnson" = "C:\Users\k.johnson\AppData\Local\Temp"
    "e.brown"   = "C:\Users\e.brown\AppData\Local\Temp"
}
$temp_items = @("implant.rar", "implant_drop.rar", "impl.ps1", "wupd")

foreach ($label in $temp_users.Keys) {
    $dir = $temp_users[$label]
    foreach ($item in $temp_items) {
        Check-Path "$dir\$item" "Temp\$label\$item"
    }
}

# ── Old WindowsUpdate.ps1 ─────────────────────────────────────────────────────
Write-Host "`n[Legacy Files]" -ForegroundColor Yellow
Check-Path "$env:APPDATA\Microsoft\WindowsUpdate.ps1" "WindowsUpdate.ps1 (old persist)"

# ── Remote WS-2 (SMB з кредами e.brown) ──────────────────────────────────────
$currentHost = $env:COMPUTERNAME
if ($currentHost -ne "WS-2") {
    Write-Host "`n[Remote WS-2 via SMB]" -ForegroundColor Yellow
    $ws2 = "192.168.210.102"
    $share = "\\$ws2\C$"

    # Підключаємось з кредами (з файлу або fallback)
    $wu = "e.brown"; $wp = "W!lDc@T22"
    $creds_csv = Get-ChildItem "C:\ProgramData\upd_logs\creds" -Filter "*.csv" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($creds_csv) {
        $cred_line = Get-Content $creds_csv.FullName |
            Where-Object { $_ -notmatch "^user" -and $_ -match "e\.brown" } | Select-Object -First 1
        if ($cred_line) { $cp = $cred_line.Split(','); $wu = $cp[0].Trim(); $wp = $cp[1].Trim() }
    }
    $ws2_connected = $false
    net use $share /delete 2>$null | Out-Null
    foreach ($fmt in @("GOV.LOCAL\$wu", "$ws2\$wu", $wu)) {
        $r = net use $share /user:$fmt $wp 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ws2_connected = $true
            Write-Host "  Connected to WS-2 as $fmt" -ForegroundColor DarkGray
            break
        }
    }

    if ($ws2_connected) {
        # wsu.lock
        Check-Path "$share\Windows\Temp\wsu.lock" "WS-2 wsu.lock"

        # Scripts in Windows\Temp
        Get-ChildItem "$share\Windows\Temp" -Filter "*.ps1" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "  [FOUND] WS-2 Windows\Temp\$($_.Name)" -ForegroundColor Red; $script:found++
        }
        Get-ChildItem "$share\Windows\Temp" -Filter "*.bat" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "  [FOUND] WS-2 Windows\Temp\$($_.Name)" -ForegroundColor Red; $script:found++
        }

        # All-Users Startup
        $ws2_all_startup = "$share\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
        foreach ($f in $startup_files) {
            Check-Path "$ws2_all_startup\$f" "WS-2 AllUsers Startup\$f"
        }

        # Per-user Startup + WinUpd (всі профілі)
        Get-ChildItem "$share\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') } |
            ForEach-Object {
                $uname = $_.Name
                $user_startup = "$share\Users\$uname\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
                foreach ($f in $startup_files) {
                    Check-Path "$user_startup\$f" "WS-2 Startup\$uname\$f"
                }
                Check-Path "$share\Users\$uname\AppData\Roaming\Microsoft\WinUpd" "WS-2 WinUpd\$uname"
            }

        # upd_logs (якщо block1 вже запускався на WS-2)
        Check-Path "$share\ProgramData\upd_logs" "WS-2 upd_logs"

        net use $share /delete 2>$null | Out-Null
    } else {
        Write-Host "  WS-2 ($ws2) недоступний або немає кредів" -ForegroundColor DarkGray
        Write-Host "  (запусти check_artifacts.ps1 на WS-2 консолі для локальної перевірки)" -ForegroundColor DarkGray
    }
}

# ── File Server (FILES-01): артефакти block7 ─────────────────────────────────
Write-Host "`n[File Server / Block7]" -ForegroundColor Yellow

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

if ($b7_shares.Count -eq 0) {
    Write-Host "  [clean] Mapped shares not found" -ForegroundColor DarkGreen
} else {
    foreach ($share in $b7_shares) {
        if (-not (Test-Path $share)) {
            Write-Host "  [skip]  Share недоступна: $share" -ForegroundColor DarkGray
            continue
        }
        Check-Path "$share\.winsec"                    "FileServer .winsec marker ($share)"
        Check-Path "$share\WindowsSecurityUpdate.vbs"  "FileServer VBS fallback ($share)"
        Get-ChildItem $share -Filter "*.docm" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "  [FOUND] FileServer .docm: $($_.Name)" -ForegroundColor Red; $script:found++
        }
        Get-ChildItem $share -Filter "*.xlsm" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Host "  [FOUND] FileServer .xlsm: $($_.Name)" -ForegroundColor Red; $script:found++
        }
    }
}

# AccessVBOM
Get-ChildItem "HKCU:\Software\Microsoft\Office" -ErrorAction SilentlyContinue | ForEach-Object {
    foreach ($app in @("Word", "Excel")) {
        $path = "HKCU:\Software\Microsoft\Office\$($_.PSChildName)\$app\Security"
        if (Test-Path $path) {
            $val = (Get-ItemProperty $path -ErrorAction SilentlyContinue).AccessVBOM
            if ($val -eq 1) {
                Write-Host "  [FOUND] Office $app AccessVBOM=1 (version $($_.PSChildName))" -ForegroundColor Red
                $script:found++
            }
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n=== Результат ===" -ForegroundColor Cyan
if ($found -eq 0) {
    Write-Host "  Чисто — артефактів не знайдено" -ForegroundColor Green
} else {
    Write-Host "  Знайдено артефактів : $found" -ForegroundColor Red
    Write-Host "  Чисто               : $clean" -ForegroundColor DarkGreen
    Write-Host "`n  Запусти reset.ps1 щоб очистити" -ForegroundColor Yellow
}
