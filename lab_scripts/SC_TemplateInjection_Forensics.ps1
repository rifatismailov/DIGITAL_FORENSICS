<#
.SYNOPSIS
Форензічний аналіз Template Injection у документах Word (.docx, .doc).
Скрипт ТІЛЬКИ ЧИТАЄ та документує — жоден файл не змінюється і не видаляється.

.DESCRIPTION
- Сканує всі локальні диски на наявність .docx та .doc файлів
- Перевіряє settings.xml.rels на наявність віддалених шаблонів (http, smb, ftp)
- Документує знайдені URL шаблонів як IoC (Indicator of Compromise)
- Генерує CSV звіт та текстовий підсумок
- Оригінальні файли НЕ ЗМІНЮЮТЬСЯ

MITRE ATT&CK: T1221 (Template Injection)

.EXAMPLE
    PS> .\SC_TemplateInjection_Forensics.ps1
#>

# ─── Ініціалізація ────────────────────────────────────────────────────────────

$DesktopPath = [Environment]::GetFolderPath("Desktop")
$ProcFolder  = (Get-Date -Format 'yyyyMMdd_HHmm') + '_TemplateInjection_Forensics'
$OutputDir   = Join-Path $DesktopPath $ProcFolder
$TempDir     = Join-Path $OutputDir 'TempExtract'

New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
New-Item -Path $TempDir   -ItemType Directory -Force | Out-Null

$LogPath = Join-Path $OutputDir "$(Get-Date -Format yyyyMMdd_HHmm)_TemplateInjection_Log.txt"
$CsvPath = Join-Path $OutputDir "$(Get-Date -Format yyyyMMdd_HHmm)_TemplateInjection_Report.csv"

function Write-Log {
    param([string]$Message, [ValidateSet('Info','Warn','Error')][string]$Level = 'Info')
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" |
        Out-File -FilePath $LogPath -Append -Encoding utf8
}

function Write-Report {
    param([string]$Text)
    $Text | Out-File -FilePath $LogPath -Append -Encoding utf8
}

# ─── Функція: аналіз .docx через ZIP розпакування ────────────────────────────

function Get-DocxTemplateInjection {
    param([string]$FilePath, [string]$TempFolder)

    $BaseName   = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $ExtractDir = Join-Path $TempFolder "docx_$BaseName$(Get-Random -Maximum 9999)"
    $ZipCopy    = Join-Path $TempFolder "$BaseName.zip"

    $RemoteTemplate = $null
    $TemplateType   = $null

    try {
        # Копіюємо .docx → .zip (не чіпаємо оригінал)
        Copy-Item $FilePath -Destination $ZipCopy -Force -EA Stop
        Expand-Archive -Path $ZipCopy -DestinationPath $ExtractDir -Force -EA Stop

        $RelsFile = Join-Path $ExtractDir 'word\_rels\settings.xml.rels'
        if (Test-Path $RelsFile) {
            [xml]$Xml  = Get-Content $RelsFile -Encoding utf8
            $Nodes     = $Xml.Relationships.ChildNodes

            foreach ($Node in $Nodes) {
                $Target = $Node.Target
                if ($Target -match '(https?:\/\/|s?ftps?:\/\/|^\\\\)') {
                    $RemoteTemplate = $Target
                    $TemplateType   = $Node.Type
                    break
                }
            }
        }
    } catch {
        Write-Log "Помилка обробки $FilePath : $_" -Level Error
    } finally {
        # Видаляємо тільки ТИМЧАСОВІ копії, оригінал не чіпаємо
        Remove-Item $ZipCopy    -Force -EA SilentlyContinue
        Remove-Item $ExtractDir -Recurse -Force -EA SilentlyContinue
    }

    return [PSCustomObject]@{
        File            = $FilePath
        Extension       = '.docx'
        RemoteTemplate  = $RemoteTemplate
        TemplateType    = $TemplateType
        IsInjected      = ($null -ne $RemoteTemplate)
    }
}

# ─── Функція: аналіз .doc через Word COM ─────────────────────────────────────

function Get-DocTemplateInjection {
    param([string]$FilePath)

    $RemoteTemplate = $null
    $TemplateType   = $null
    $AppObj         = $null

    try {
        $AppObj = New-Object -ComObject Word.Application
        $AppObj.Visible = $false
        $AppObj.AutomationSecurity = "msoAutomationSecurityForceDisable"

        $Doc = $AppObj.Documents.Open($FilePath, $false, $true)  # ReadOnly = $true

        [xml]$XmlData = $Doc.AttachedTemplate.Parent.ActiveDocument.WordOpenXML
        $Relations    = $XmlData.package.part.xmlData.Relationships.Relationship

        foreach ($Rel in $Relations) {
            if ($Rel.type -notmatch 'hyperlink$' -and
                ($Rel.target -match '(https?:\/\/|s?ftps?:\/\/|^\\\\)')) {
                $RemoteTemplate = $Rel.target
                $TemplateType   = $Rel.type
                break
            }
        }
        $Doc.Close($false)
    } catch {
        Write-Log "Помилка обробки $FilePath : $_" -Level Error
    } finally {
        if ($AppObj) { $AppObj.Quit(); [System.Runtime.InteropServices.Marshal]::ReleaseComObject($AppObj) | Out-Null }
    }

    return [PSCustomObject]@{
        File            = $FilePath
        Extension       = '.doc'
        RemoteTemplate  = $RemoteTemplate
        TemplateType    = $TemplateType
        IsInjected      = ($null -ne $RemoteTemplate)
    }
}

# ─── Старт ───────────────────────────────────────────────────────────────────

Write-Report ("=" * 60)
Write-Report "ФОРЕНЗІЧНИЙ АНАЛІЗ TEMPLATE INJECTION"
Write-Report "Дата:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Report "Система:  $env:COMPUTERNAME"
Write-Report "Користувач: $env:USERNAME"
Write-Report "УВАГА: Скрипт тільки читає — файли не змінюються!"
Write-Report ("=" * 60)
Write-Log "Початок сканування"

'File,Extension,IsInjected,RemoteTemplate,TemplateType' |
    Out-File $CsvPath -Encoding utf8

$TotalDocs = 0; $TotalInjected = 0

$Disks = Get-PSDrive -PSProvider FileSystem | Where-Object Used -GT 0

foreach ($Disk in $Disks.Root) {
    Write-Host "[>] Сканування $Disk ..." -ForegroundColor DarkCyan
    Write-Log "Сканування $Disk"

    $Files = Get-ChildItem "$($Disk)*" -Directory -Force -EA Silent |
        Where-Object Name -notmatch '^(Windows|Program Files|Program Files \(x86\))$' |
        Get-ChildItem -Recurse -Include '*.docx','*.doc' -EA Ignore

    foreach ($File in $Files) {
        $TotalDocs++
        Write-Host "[>] Аналіз: $($File.Name)" -ForegroundColor DarkGray
        Write-Log "Аналіз: $($File.FullName)"

        $Result = if ($File.Extension -eq '.docx') {
            Get-DocxTemplateInjection -FilePath $File.FullName -TempFolder $TempDir
        } else {
            Get-DocTemplateInjection  -FilePath $File.FullName
        }

        if ($Result.IsInjected) {
            $TotalInjected++
            Write-Host "[!!!] TEMPLATE INJECTION: $($File.FullName)" -ForegroundColor Red
            Write-Host "      Віддалений шаблон: $($Result.RemoteTemplate)" -ForegroundColor Yellow
            Write-Host "      Тип:                $($Result.TemplateType)" -ForegroundColor Yellow
            Write-Log "TEMPLATE INJECTION: $($File.FullName) | URL: $($Result.RemoteTemplate)" -Level Warn
            Write-Report "`n[!!!] $($File.FullName)"
            Write-Report "      IoC URL: $($Result.RemoteTemplate -replace 'http','hxxp')"
        }

        "`"$($Result.File)`",`"$($Result.Extension)`",`"$($Result.IsInjected)`",`"$($Result.RemoteTemplate -replace 'http','hxxp')`",`"$($Result.TemplateType)`"" |
            Out-File $CsvPath -Append -Encoding utf8
    }
}

# Очищення тимчасової папки
Remove-Item $TempDir -Recurse -Force -EA SilentlyContinue

# ─── Підсумок ────────────────────────────────────────────────────────────────

Write-Report "`n--- ПІДСУМОК ---"
Write-Report "Всього документів проаналізовано: $TotalDocs"
Write-Report "З template injection:             $TotalInjected"
Write-Report "CSV звіт: $CsvPath"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " ПІДСУМОК TEMPLATE INJECTION ФОРЕНЗІКИ" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Всього документів:     $TotalDocs" -ForegroundColor White
if ($TotalInjected -gt 0) {
    Write-Host " З ін'єкцією шаблону:   $TotalInjected" -ForegroundColor Red
    Write-Host " IoC URL збережено у:   $CsvPath" -ForegroundColor Yellow
} else {
    Write-Host " З ін'єкцією шаблону:   0 (норма)" -ForegroundColor Green
}
Write-Host " Результати збережено:  $OutputDir" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

Invoke-Item $OutputDir
