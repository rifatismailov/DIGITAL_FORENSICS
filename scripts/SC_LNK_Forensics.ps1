<#
.SYNOPSIS
Форензічний аналіз .LNK файлів на локальних дисках.
Скрипт ТІЛЬКИ ЧИТАЄ та документує — жоден файл не переміщується і не видаляється.

.DESCRIPTION
- Сканує всі локальні диски на наявність .LNK файлів
- Для кожного файлу витягує: TargetPath, Arguments, IconLocation
- Позначає підозрілі файли (цілі cmd.exe/powershell.exe/mshta.exe/rundll32.exe/wscript.exe або URL в аргументах)
- Зберігає повний CSV звіт та текстовий підсумок на Робочому столі
- Оригінальні файли НЕ ЗМІНЮЮТЬСЯ

MITRE ATT&CK: T1547.009 (Shortcut Modification), T1204.002 (Malicious File)

.EXAMPLE
    PS> .\SC_LNK_Forensics.ps1
#>

# ─── Ініціалізація ────────────────────────────────────────────────────────────

$DesktopPath    = [Environment]::GetFolderPath("Desktop")
$ProcFolder     = (Get-Date -Format 'yyyyMMdd_HHmm') + '_LNK_Forensics'
$OutputDir      = Join-Path $DesktopPath $ProcFolder
$TempProcessing = Join-Path $OutputDir 'TempProcessing'

New-Item -Path $OutputDir      -ItemType Directory -Force | Out-Null
New-Item -Path $TempProcessing -ItemType Directory -Force | Out-Null

$LogPath  = Join-Path $OutputDir "$(Get-Date -Format yyyyMMdd_HHmm)_LNK_ForensicsLog.txt"
$CsvPath  = Join-Path $OutputDir "$(Get-Date -Format yyyyMMdd_HHmm)_LNK_Report.csv"

function Write-Log {
    param([string]$Message, [ValidateSet('Info','Warn','Error')][string]$Level = 'Info')
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    $line | Out-File -FilePath $LogPath -Append -Encoding utf8
}

function Write-Report {
    param([string]$Text)
    $Text | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# ─── Функція: зчитати деталі .LNK (з підтримкою кирилиці) ────────────────────

function Get-LnkDetails {
    param(
        [string]$FileToProcess,
        [string]$ProcessingFolder
    )
    $ExtCheck = Get-ChildItem $FileToProcess -Force -EA SilentlyContinue | Select-Object -ExpandProperty Extension

    # Файли з кирилицею або нестандартним розширенням — копіюємо з ASCII назвою
    if (($FileToProcess -match '(\w+[Ѐ-ԯ]+)|([Ѐ-ԯ]+\w+)') -or ($ExtCheck -ne '.lnk')) {
        $TempName = "LnkProc$(Get-Random -Maximum 99999).lnk"
        $TempFile = Join-Path $ProcessingFolder $TempName
        Copy-Item $FileToProcess -Destination $TempFile -Force -EA SilentlyContinue
        $Shell    = New-Object -ComObject WScript.Shell
        $SC       = $Shell.CreateShortcut($TempFile)
        $Result   = [PSCustomObject]@{
            Fullname     = $FileToProcess
            TargetPath   = $SC.TargetPath
            Arguments    = $SC.Arguments
            IconLocation = $SC.IconLocation
        }
        Remove-Item $TempFile -Force -EA SilentlyContinue
        return $Result
    }

    $Shell = New-Object -ComObject WScript.Shell
    return $Shell.CreateShortcut($FileToProcess)
}

# ─── Функція: перевірити чи це системний (легітимний) ярлик ──────────────────

function Test-SystemLnk {
    param([object]$LNKFile)
    $LegitNames = @(
        'Command Prompt.lnk','computer.lnk','Control Panel.lnk',
        'File Explorer.lnk','Run.lnk','Search.lnk',
        'Windows PowerShell (x86).lnk','Windows PowerShell.lnk'
    )
    $Parts = $LNKFile.Fullname -split '\\'
    if ($Parts | Where-Object { $_ -eq 'AppData' -or $_ -eq 'All Users' -or $_ -eq 'ProgramData' }) {
        if ($Parts | Where-Object { $_ -eq 'WinX' }) { return $true }
        if (($Parts | Where-Object { $_ -eq 'System Tools' -or $_ -eq 'Programs' }) -and
            ($LegitNames | Where-Object { $Parts -contains $_ })) { return $true }
    }
    return $false
}

# ─── Старт ───────────────────────────────────────────────────────────────────

Write-Report "=" * 60
Write-Report "ФОРЕНЗІЧНИЙ АНАЛІЗ .LNK ФАЙЛІВ"
Write-Report "Дата:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Report "Система:  $env:COMPUTERNAME"
Write-Report "Користувач: $env:USERNAME"
Write-Report "УВАГА: Скрипт тільки читає — файли не змінюються!"
Write-Report ("=" * 60)
Write-Log "Початок сканування"

# Заголовок CSV
'LnkFileName,LnkFullPath,TargetPath,Arguments,IconLocation,IsSystemLnk,SuspiciousTarget,SuspiciousArgs,SuspiciousReason' |
    Out-File $CsvPath -Encoding utf8

$SuspiciousBinaries = @('cmd.exe','powershell.exe','mshta.exe','rundll32.exe','wscript.exe','cscript.exe','regsvr32.exe')

# ─── Сканування дисків ────────────────────────────────────────────────────────

$Disks = Get-PSDrive -PSProvider FileSystem | Where-Object Used -GT 0
$TotalFound = 0; $TotalSuspicious = 0

foreach ($Disk in $Disks.Root) {
    Write-Host "[>] Сканування $Disk ..." -ForegroundColor DarkCyan
    Write-Log "Сканування $Disk"

    $LnkFiles = Get-Item "$($Disk)*" -Exclude 'Windows','Program Files','Program Files (x86)' -Force -EA Silent |
        Get-ChildItem -Recurse -EA Ignore -Force |
        Where-Object { $_.Extension -match '(\.lnk(?=[^.]*$))' }

    foreach ($File in $LnkFiles) {
        $TotalFound++
        $SC = Get-LnkDetails -FileToProcess $File.FullName -ProcessingFolder $TempProcessing

        $TargetBin       = Split-Path ($SC.TargetPath) -Leaf
        $SuspTarget      = $SuspiciousBinaries -contains $TargetBin
        $SuspArgs        = ($SC.Arguments -match '(https?:\/\/|w{3}?\.)') -as [bool]
        $IsSystem        = Test-SystemLnk -LNKFile $SC
        $SuspiciousReason = ''

        if ($SuspTarget)  { $SuspiciousReason += "Підозрілий target: $TargetBin; " }
        if ($SuspArgs)    { $SuspiciousReason += "URL в Arguments: $($SC.Arguments); " }

        $IsSuspicious = ($SuspTarget -or $SuspArgs) -and (-not $IsSystem)

        if ($IsSuspicious) {
            $TotalSuspicious++
            Write-Host "[!!!] ПІДОЗРІЛИЙ: $($File.FullName)" -ForegroundColor Red
            Write-Host "      Target:    $($SC.TargetPath)" -ForegroundColor Yellow
            Write-Host "      Arguments: $($SC.Arguments)" -ForegroundColor Yellow
            Write-Log "ПІДОЗРІЛИЙ LNK: $($File.FullName) | Target: $($SC.TargetPath) | Args: $($SC.Arguments)" -Level Warn
        }

        # Запис у CSV
        "`"$($File.Name)`",`"$($File.FullName)`",`"$($SC.TargetPath)`",`"$($SC.Arguments)`",`"$($SC.IconLocation)`",`"$IsSystem`",`"$SuspTarget`",`"$SuspArgs`",`"$SuspiciousReason`"" |
            Out-File $CsvPath -Append -Encoding utf8
    }
}

# Очищення тимчасової папки
Remove-Item $TempProcessing -Recurse -Force -EA SilentlyContinue

# ─── Підсумок ────────────────────────────────────────────────────────────────

Write-Report "`n--- ПІДСУМОК ---"
Write-Report "Всього .LNK файлів проаналізовано: $TotalFound"
Write-Report "Підозрілих файлів виявлено:        $TotalSuspicious"
Write-Report "CSV звіт: $CsvPath"
Write-Report "Лог:      $LogPath"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " ПІДСУМОК LNK ФОРЕНЗІКИ" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Всього проаналізовано: $TotalFound" -ForegroundColor White
if ($TotalSuspicious -gt 0) {
    Write-Host " Підозрілих знайдено:   $TotalSuspicious" -ForegroundColor Red
} else {
    Write-Host " Підозрілих знайдено:   0 (норма)" -ForegroundColor Green
}
Write-Host " Результати збережено:  $OutputDir" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Invoke-Item $OutputDir
