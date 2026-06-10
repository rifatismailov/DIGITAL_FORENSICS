<#
.SYNOPSIS
Форензічний аналіз VBA макросів у документах Word та Excel.
Скрипт ТІЛЬКИ ЧИТАЄ та документує — жоден файл не змінюється і не видаляється.

.DESCRIPTION
- Сканує всі локальні диски на наявність .doc, .docm, .xls, .xlsm
- Для кожного документа перевіряє наявність VBA макросів
- Експортує код макросів у .vba файли для аналізу (оригінали НЕ ЗМІНЮЮТЬСЯ)
- Генерує CSV звіт та текстовий підсумок
- Макроси відкриваються з вимкненим виконанням (AutomationSecurity = ForceDisable)

MITRE ATT&CK: T1059.005 (VBA), T1566.001 (Spearphishing Attachment)

.EXAMPLE
    PS> .\SC_Macro_Forensics.ps1
#>

# ─── Ініціалізація ────────────────────────────────────────────────────────────

$DesktopPath  = [Environment]::GetFolderPath("Desktop")
$ProcFolder   = (Get-Date -Format 'yyyyMMdd_HHmm') + '_Macro_Forensics'
$OutputDir    = Join-Path $DesktopPath $ProcFolder
$MacroExport  = Join-Path $OutputDir 'ExtractedMacros'

New-Item -Path $OutputDir   -ItemType Directory -Force | Out-Null
New-Item -Path $MacroExport -ItemType Directory -Force | Out-Null

$LogPath = Join-Path $OutputDir "$(Get-Date -Format yyyyMMdd_HHmm)_Macro_ForensicsLog.txt"
$CsvPath = Join-Path $OutputDir "$(Get-Date -Format yyyyMMdd_HHmm)_Macro_Report.csv"

function Write-Log {
    param([string]$Message, [ValidateSet('Info','Warn','Error')][string]$Level = 'Info')
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding utf8
}

function Write-Report {
    param([string]$Text)
    $Text | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# ─── Функція: аналіз макросів у документі ────────────────────────────────────

function Get-DocumentMacros {
    param(
        [string]$FilePath,
        [string]$MacroFolder
    )

    $Extension  = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $BaseName   = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $HasMacros  = $false
    $MacroFiles = @()
    $MacroNames = @()
    $AppObj     = $null

    try {
        if ($Extension -in '.doc', '.docm') {
            $AppObj = New-Object -ComObject Word.Application
            $AppObj.Visible = $false
            $AppObj.AutomationSecurity = "msoAutomationSecurityForceDisable"  # макроси НЕ виконуються

            $Doc = $AppObj.Documents.Open($FilePath, $false, $true)  # ReadOnly = $true

            if ($Doc.HasVBProject) {
                $HasMacros = $true
                foreach ($Component in $Doc.VBProject.VBComponents) {
                    $LineCount = $Component.CodeModule.CountOfLines
                    if ($LineCount -gt 0) {
                        $Code      = $Component.CodeModule.Lines(1, $LineCount)
                        $MacroFile = Join-Path $MacroFolder "${BaseName}__$($Component.Name).vba"
                        $Code | Out-File -FilePath $MacroFile -Encoding utf8
                        $MacroFiles += $MacroFile
                        $MacroNames += $Component.Name
                    }
                }
            }
            $Doc.Close($false)  # закрити БЕЗ збереження

        } elseif ($Extension -in '.xls', '.xlsm') {
            $AppObj = New-Object -ComObject Excel.Application
            $AppObj.Visible = $false
            $AppObj.AutomationSecurity = 3  # msoAutomationSecurityForceDisable

            $Wb = $AppObj.Workbooks.Open($FilePath, 0, $true)  # ReadOnly = $true

            if ($Wb.HasVBProject) {
                $HasMacros = $true
                foreach ($Component in $Wb.VBProject.VBComponents) {
                    $LineCount = $Component.CodeModule.CountOfLines
                    if ($LineCount -gt 0) {
                        $Code      = $Component.CodeModule.Lines(1, $LineCount)
                        $MacroFile = Join-Path $MacroFolder "${BaseName}__$($Component.Name).vba"
                        $Code | Out-File -FilePath $MacroFile -Encoding utf8
                        $MacroFiles += $MacroFile
                        $MacroNames += $Component.Name
                    }
                }
            }
            $Wb.Close($false)
        }
    } catch {
        Write-Log "Помилка обробки $FilePath : $_" -Level Error
    } finally {
        if ($AppObj) { $AppObj.Quit(); [System.Runtime.InteropServices.Marshal]::ReleaseComObject($AppObj) | Out-Null }
    }

    return [PSCustomObject]@{
        File          = $FilePath
        Extension     = $Extension
        HasMacros     = $HasMacros
        MacroCount    = $MacroNames.Count
        MacroNames    = ($MacroNames -join '; ')
        ExportedFiles = ($MacroFiles -join '; ')
    }
}

# ─── Старт ───────────────────────────────────────────────────────────────────

Write-Report ("=" * 60)
Write-Report "ФОРЕНЗІЧНИЙ АНАЛІЗ VBA МАКРОСІВ"
Write-Report "Дата:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Report "Система:  $env:COMPUTERNAME"
Write-Report "Користувач: $env:USERNAME"
Write-Report "УВАГА: Скрипт тільки читає — файли не змінюються!"
Write-Report ("=" * 60)
Write-Log "Початок сканування"

'File,Extension,HasMacros,MacroCount,MacroNames,ExportedFiles' |
    Out-File $CsvPath -Encoding utf8

$TotalDocs = 0; $TotalWithMacros = 0

$Disks = Get-PSDrive -PSProvider FileSystem | Where-Object Used -GT 0

foreach ($Disk in $Disks.Root) {
    Write-Host "[>] Сканування $Disk ..." -ForegroundColor DarkCyan
    Write-Log "Сканування $Disk"

    $Files = Get-ChildItem "$($Disk)*" -Directory -Force -EA Silent |
        Where-Object Name -notmatch '^(Windows|Program Files|Program Files \(x86\))$' |
        Get-ChildItem -Recurse -Include '*.doc','*.docm','*.xls','*.xlsm' -EA Ignore

    foreach ($File in $Files) {
        $TotalDocs++
        Write-Host "[>] Аналіз: $($File.Name)" -ForegroundColor DarkGray
        Write-Log "Аналіз: $($File.FullName)"

        $Result = Get-DocumentMacros -FilePath $File.FullName -MacroFolder $MacroExport

        if ($Result.HasMacros) {
            $TotalWithMacros++
            Write-Host "[!!!] МАКРОСИ ЗНАЙДЕНО: $($File.FullName)" -ForegroundColor Red
            Write-Host "      Модулі: $($Result.MacroNames)" -ForegroundColor Yellow
            Write-Host "      Експортовано у: $MacroExport" -ForegroundColor Yellow
            Write-Log "МАКРОСИ: $($File.FullName) | Модулі: $($Result.MacroNames)" -Level Warn
        }

        "`"$($Result.File)`",`"$($Result.Extension)`",`"$($Result.HasMacros)`",`"$($Result.MacroCount)`",`"$($Result.MacroNames)`",`"$($Result.ExportedFiles)`"" |
            Out-File $CsvPath -Append -Encoding utf8
    }
}

# ─── Підсумок ────────────────────────────────────────────────────────────────

Write-Report "`n--- ПІДСУМОК ---"
Write-Report "Всього документів проаналізовано: $TotalDocs"
Write-Report "Документів з макросами:           $TotalWithMacros"
Write-Report "Код макросів збережено у:         $MacroExport"
Write-Report "CSV звіт: $CsvPath"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " ПІДСУМОК MACRO ФОРЕНЗІКИ" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Всього документів:     $TotalDocs" -ForegroundColor White
if ($TotalWithMacros -gt 0) {
    Write-Host " З макросами:           $TotalWithMacros" -ForegroundColor Red
    Write-Host " Код збережено у:       $MacroExport" -ForegroundColor Yellow
} else {
    Write-Host " З макросами:           0 (норма)" -ForegroundColor Green
}
Write-Host " Результати збережено:  $OutputDir" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Invoke-Item $OutputDir
