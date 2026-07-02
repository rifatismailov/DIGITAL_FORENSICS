# =============================================================================
# Block 3: Network Scan для навчання заборонено використовувати в оц
# EXERCISE ONLY — Blue Team Training
# =============================================================================
# Що робить:
#   Автоматично визначає підмережу → сканує 5 протоколами:
#   1. ICMP  — ping sweep (живі хости)
#   2. SMB   — TCP/445 (Windows машини)
#   3. RDP   — TCP/3389 (робочі станції)
#   4. DNS   — reverse lookup (hostname)
#   5. NetBIOS — UDP/137 (імена машин)
# Артефакти для blue team:
#   - Arkime: ICMP flood, TCP SYN до 445/3389, UDP/137, DNS reverse
#   - Wazuh:  network connection events
#   - Результат: hosts.txt в %TEMP%\upd_logs\
# =============================================================================

$BLOCK_TAG = "B3"
$LogPath   = "C:\ProgramData\upd_logs\block3.log"
. "$PSScriptRoot\config.ps1"

# ── Отримати підмережу автоматично ───────────────────────────────────────────
function Get-LocalSubnet {
    $nic = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -notmatch '^127\.' -and
            $_.IPAddress -notmatch '^169\.254\.'
        } | Select-Object -First 1

    if (-not $nic) { return $null }

    $octets = $nic.IPAddress -split '\.'
    $base   = "$($octets[0]).$($octets[1]).$($octets[2])"

    return @{
        MyIP   = $nic.IPAddress
        Base   = $base
        Prefix = $nic.PrefixLength
    }
}

# ── 1. ICMP Ping Sweep (parallel runspaces) ──────────────────────────────────
function Invoke-IcmpSweep {
    param(
        [string]$Base,
        [int]$TimeoutMs     = 800,
        [int]$ThrottleLimit = 50
    )
    Write-Log "Starting ICMP sweep: $Base.1-254 (parallel, timeout=${TimeoutMs}ms)"

    $pool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit)
    $pool.Open()

    $sb = {
        param($ip, $ms)
        try {
            $ping   = New-Object System.Net.NetworkInformation.Ping
            $result = $ping.Send($ip, $ms)
            if ($result.Status -eq 'Success') { return $ip }
        } catch {}
        return $null
    }

    $jobs = 1..254 | ForEach-Object {
        $ip = "$Base.$_"
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        $ps.AddScript($sb).AddArgument($ip).AddArgument($TimeoutMs) | Out-Null
        [PSCustomObject]@{ PS = $ps; H = $ps.BeginInvoke() }
    }

    $live = @()
    foreach ($j in $jobs) {
        $r = $j.PS.EndInvoke($j.H)
        if ($r) {
            $live += $r
            Write-Log "ICMP alive: $r"
        }
        $j.PS.Dispose()
    }
    $pool.Close(); $pool.Dispose()

    Write-Log "ICMP sweep done: $($live.Count) hosts"
    return $live
}

# ── Паралельний TCP scan через runspaces ─────────────────────────────────────
function Invoke-TcpScanParallel {
    param(
        [string[]]$Hosts,
        [int]     $Port,
        [int]     $TimeoutMs     = 500,
        [int]     $ThrottleLimit = 50
    )
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit)
    $pool.Open()

    $sb = {
        param($ip, $port, $ms)
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar  = $tcp.BeginConnect($ip, $port, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne($ms, $false)) {
                $tcp.EndConnect($ar); $tcp.Close(); return $ip
            }
            $tcp.Close()
        } catch {}
        return $null
    }

    $jobs = foreach ($ip in $Hosts) {
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        $ps.AddScript($sb).AddArgument($ip).AddArgument($Port).AddArgument($TimeoutMs) | Out-Null
        [PSCustomObject]@{ PS = $ps; H = $ps.BeginInvoke() }
    }

    $results = @()
    foreach ($j in $jobs) {
        $r = $j.PS.EndInvoke($j.H)
        if ($r) { $results += $r }
        $j.PS.Dispose()
    }
    $pool.Close(); $pool.Dispose()
    return $results
}

# ── 2. SMB Scan TCP/445 ───────────────────────────────────────────────────────
function Invoke-SmbScan {
    param([string[]]$Hosts)
    Write-Log "Starting SMB scan TCP/445 parallel ($($Hosts.Count) hosts)..."
    $smb_hosts = Invoke-TcpScanParallel -Hosts $Hosts -Port 445
    foreach ($ip in $smb_hosts) { Write-Log "SMB open: $ip:445" }
    Write-Log "SMB scan done: $($smb_hosts.Count) hosts"
    return $smb_hosts
}

# ── 3. RDP Scan TCP/3389 ──────────────────────────────────────────────────────
function Invoke-RdpScan {
    param([string[]]$Hosts)
    Write-Log "Starting RDP scan TCP/3389 parallel ($($Hosts.Count) hosts)..."
    $rdp_hosts = Invoke-TcpScanParallel -Hosts $Hosts -Port 3389
    foreach ($ip in $rdp_hosts) { Write-Log "RDP open: $ip:3389" }
    Write-Log "RDP scan done: $($rdp_hosts.Count) hosts"
    return $rdp_hosts
}

# ── 4. DNS Reverse Lookup ─────────────────────────────────────────────────────
function Invoke-DnsReverseLookup {
    param([string[]]$Hosts)
    Write-Log "Starting DNS reverse lookup..."
    $dns_results = @{}
    foreach ($ip in $Hosts) {
        $result = Resolve-DnsName -Name $ip -Type PTR -ErrorAction SilentlyContinue
        if ($result) {
            $hostname = $result.NameHost
            $dns_results[$ip] = $hostname
            Write-Log "DNS: $ip → $hostname"
        }
    }
    Write-Log "DNS lookup done: $($dns_results.Count) resolved"
    return $dns_results
}

# ── 5. NetBIOS Scan UDP/137 ───────────────────────────────────────────────────
function Invoke-NetBiosScan {
    param([string[]]$Hosts)
    Write-Log "Starting NetBIOS scan (UDP/137)..."
    $netbios_hosts = @{}
    foreach ($ip in $Hosts) {
        try {
            $result = nbtstat -A $ip 2>&1
            if ($result -match '<00>') {
                $name = ($result | Select-String '<00>\s+UNIQUE' |
                    ForEach-Object { $_.Line.Trim().Split()[0] }) | Select-Object -First 1
                $netbios_hosts[$ip] = $name
                Write-Log "NetBIOS: $ip → $name"
            }
        } catch {}
    }
    Write-Log "NetBIOS scan done: $($netbios_hosts.Count) hosts"
    return $netbios_hosts
}

# =============================================================================
Write-Log "=== BLOCK 3: NETWORK SCAN START ==="
Invoke-DnsBeacon -Label "B3:START:$env:COMPUTERNAME"

# ── Визначаємо підмережу автоматично ─────────────────────────────────────────
$subnet = Get-LocalSubnet
if (-not $subnet) {
    Write-Log "Cannot determine local subnet!" -Level "ERROR"
    Invoke-DnsBeacon -Label "B3:ERROR:NO_SUBNET"
    exit
}

Write-Log "My IP: $($subnet.MyIP) | Scanning: $($subnet.Base).1-254"
Invoke-DnsBeacon -Label "B3:SUBNET:$($subnet.Base)"

# ── 1. ICMP sweep (інформаційно — не блокує подальше сканування) ─────────────
$icmp_hosts = Invoke-IcmpSweep -Base $subnet.Base
Invoke-DnsBeacon -Label "B3:ICMP:$($icmp_hosts.Count)"
Write-Log "ICMP alive: $($icmp_hosts.Count) — але SMB сканується по всій підмережі"

# ── 2. SMB scan — по всіх 254 IP незалежно від ICMP ─────────────────────────
# ICMP може бути заблокований (firewall) — тому не використовуємо як фільтр
$all_ips  = 1..254 | ForEach-Object { "$($subnet.Base).$_" }
$smb_hosts = Invoke-SmbScan -Hosts $all_ips
Invoke-DnsBeacon -Label "B3:SMB:$($smb_hosts.Count)"

if ($smb_hosts.Count -eq 0) {
    Write-Log "No SMB hosts found" -Level "WARN"
    Invoke-DnsBeacon -Label "B3:DONE:NO_HOSTS"
    $LOG_DIR    = "C:\ProgramData\upd_logs"
    $HOSTS_FILE = "$LOG_DIR\hosts.txt"
    "NETWORK SCAN REPORT — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`nNo live hosts found." |
        Out-File -FilePath $HOSTS_FILE -Encoding UTF8
    Write-Log "=== BLOCK 3: COMPLETE (no hosts) ==="
    exit
}

# Об'єднуємо ICMP + SMB для повного списку живих хостів
$live_hosts = ($icmp_hosts + $smb_hosts) | Sort-Object -Unique

# ── 3. RDP scan — тільки по хостах що відповіли на SMB або ICMP ──────────────
$rdp_hosts = Invoke-RdpScan -Hosts $live_hosts
Invoke-DnsBeacon -Label "B3:RDP:$($rdp_hosts.Count)"

# ── 4. DNS reverse lookup ─────────────────────────────────────────────────────
$dns_results = Invoke-DnsReverseLookup -Hosts $live_hosts
Invoke-DnsBeacon -Label "B3:DNS:$($dns_results.Count)"

# ── 5. NetBIOS scan ───────────────────────────────────────────────────────────
$netbios_results = Invoke-NetBiosScan -Hosts $live_hosts
Invoke-DnsBeacon -Label "B3:NETBIOS:$($netbios_results.Count)"

# ── Зберігаємо результати ─────────────────────────────────────────────────────
$LOG_DIR   = "C:\ProgramData\upd_logs"
$HOSTS_FILE = "$LOG_DIR\hosts.txt"

$report = @()
$report += "=" * 60
$report += "NETWORK SCAN REPORT — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$report += "Subnet: $($subnet.Base).0/$($subnet.Prefix)"
$report += "=" * 60

foreach ($ip in $live_hosts) {
    $hostname = if ($dns_results[$ip])     { $dns_results[$ip] }
                elseif ($netbios_results[$ip]) { $netbios_results[$ip] }
                else { "unknown" }
    $smb  = if ($smb_hosts -contains $ip) { "SMB:YES" } else { "SMB:NO" }
    $rdp  = if ($rdp_hosts -contains $ip) { "RDP:YES" } else { "RDP:NO" }

    $report += "$ip | $hostname | $smb | $rdp"
}

$report | Out-File -FilePath $HOSTS_FILE -Encoding UTF8
Write-Log "Scan results saved to: $HOSTS_FILE"

# ── Підсумок ──────────────────────────────────────────────────────────────────
Write-Log "=== BLOCK 3: COMPLETE ==="
Invoke-DnsBeacon -Label "B3:DONE:LIVE:$($live_hosts.Count)"

return $live_hosts
