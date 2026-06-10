# Лабораторна робота Сценарій 13: Аналіз Windows Event Log

Назва лабораторної: Windows Event Log Forensics — Security Event Analysis
Модуль: Цифрова криміналістика / Windows Artifacts
Сценарій: 13 Windows Event Log Analysis
Формат: Self - Paced
Версія документу: 1.0

---

## Мета

Навчитися аналізувати журнали подій Windows (Event Log) для виявлення підозрілої активності. Зрозуміти ключові Event ID та їх форензічне значення при розслідуванні інцидентів.

---

## Теоретична частина

### Основні журнали Windows Event Log

| Журнал | Розташування | Що містить |
|---|---|---|
| Security | `C:\Windows\System32\winevt\Logs\Security.evtx` | Входи, виходи, зміни прав доступу |
| System | `C:\Windows\System32\winevt\Logs\System.evtx` | Системні події, служби, драйвери |
| Application | `C:\Windows\System32\winevt\Logs\Application.evtx` | Події застосунків |
| PowerShell | `Microsoft-Windows-PowerShell/Operational.evtx` | Виконання PS команд |
| Sysmon | `Microsoft-Windows-Sysmon/Operational.evtx` | Розширений моніторинг (якщо встановлено) |

### Ключові Event ID для форензіки

| Event ID | Журнал | Подія | Форензічне значення |
|---|---|---|---|
| **4624** | Security | Успішний вхід | Хто, коли і як входив |
| **4625** | Security | Невдала спроба входу | Brute force атаки |
| **4634** | Security | Вихід з системи | Завершення сесії |
| **4648** | Security | Вхід з явними обліковими даними | Pass-the-hash атаки |
| **4688** | Security | Створення нового процесу | Запуск програм |
| **4698** | Security | Створення scheduled task | Закріплення зловмисника |
| **4720** | Security | Створення облікового запису | Backdoor users |
| **4776** | Security | Аутентифікація NTLM | Lateral movement |
| **7045** | System | Встановлення нової служби | Малварь як служба |
| **4104** | PowerShell | Виконання PS скрипту | Підозрілі команди |

### Типи входу (Logon Types)

| Logon Type | Назва | Опис |
|---|---|---|
| 2 | Interactive | Фізичний вхід за консоллю |
| 3 | Network | Мережевий вхід (SMB, RDP) |
| 4 | Batch | Заплановані завдання |
| 5 | Service | Запуск служби |
| 7 | Unlock | Розблокування екрану |
| 10 | RemoteInteractive | RDP вхід |
| 11 | CachedInteractive | Вхід з кешованими даними |

---

## Підготовка Встановлення FullEventLogView

Завантажити з офіційного сайту NirSoft:

```
https://www.nirsoft.net/utils/full_event_log_view.html
```

Розпакувати → запустити `FullEventLogView.exe`.

---

## Фаза 1 Аналіз через FullEventLogView

### Крок 1.1 Відкрити FullEventLogView

Запусти `FullEventLogView.exe`. Програма завантажить всі журнали поточної системи.

### Крок 1.2 Фільтрація за Security журналом

```
Options → Advanced Options → Log Source → Security
```

Або використай фільтр:
```
View → Use Custom Filter → Channel: Security
```

### Крок 1.3 Знайти події входу (Event ID 4624)

У полі фільтру встанови:
```
Event ID: 4624
```

Для кожного запису запиши:

| Час | Event ID | Logon Type | Account Name | Workstation |
|---|---|---|---|---|
| | 4624 | | | |
| | 4624 | | | |

### Крок 1.4 Знайти невдалі спроби входу (Event ID 4625)

```
Event ID: 4625
```

**Підозрілий патерн:** багато 4625 підряд = можлива brute force атака.

### Крок 1.5 Зберегти результати

```
File → Save Selected Items → security_events.csv
```

---

## Фаза 2 Аналіз через вбудований Event Viewer (Windows)

### Крок 2.1 Відкрити Event Viewer

```
Win+R → eventvwr.msc → Enter
```

### Крок 2.2 Створити Custom View для розслідування

```
Action → Create Custom View
    Logged: Last 7 days
    Event Level: ✅ Critical ✅ Error ✅ Warning
    By log: Windows Logs → Security
    Event IDs: 4624,4625,4648,4688,4698,4720,7045
```

### Крок 2.3 Аналіз підозрілих подій

Для кожної підозрілої події запиши:

```
Event ID:     [номер]
Час:          [дата та час]
Опис:         [текст події]
Account:      [обліковий запис]
Workstation:  [комп'ютер]
IP Address:   [якщо є]
Підозріло:    [чому це підозріло]
```

---

## Фаза 3 Аналіз через PowerShell (Windows)

### Крок 3.1 Отримати останні події безпеки

```powershell
# Останні 50 подій безпеки
Get-WinEvent -LogName Security -MaxEvents 50 | Format-Table TimeCreated, Id, Message -AutoSize
```

### Крок 3.2 Знайти всі входи за останні 24 години

```powershell
$startTime = (Get-Date).AddHours(-24)

Get-WinEvent -FilterHashtable @{
    LogName   = 'Security'
    Id        = 4624
    StartTime = $startTime
} | Select-Object TimeCreated, Id,
    @{N='Account';E={$_.Properties[5].Value}},
    @{N='LogonType';E={$_.Properties[8].Value}},
    @{N='WorkStation';E={$_.Properties[11].Value}} |
    Format-Table -AutoSize
```

### Крок 3.3 Знайти невдалі спроби входу

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    Id      = 4625
} -MaxEvents 20 | Select-Object TimeCreated,
    @{N='Account';E={$_.Properties[5].Value}},
    @{N='FailureReason';E={$_.Properties[9].Value}} |
    Format-Table -AutoSize
```

### Крок 3.4 Пошук підозрілих процесів (4688)

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    Id      = 4688
} -MaxEvents 30 | Select-Object TimeCreated,
    @{N='Process';E={$_.Properties[5].Value}},
    @{N='ParentProcess';E={$_.Properties[13].Value}} |
    Format-Table -AutoSize
```

---

## Фаза 4 Аналіз через wevtutil (командний рядок)

### Крок 4.1 Базові команди

```cmd
rem Список журналів
wevtutil el

rem Інформація про журнал Security
wevtutil gl Security

rem Останні 10 подій з Security
wevtutil qe Security /c:10 /rd:true /f:text
```

### Крок 4.2 Фільтрація за Event ID

```cmd
rem Всі події 4624 (успішний вхід)
wevtutil qe Security /q:"*[System[EventID=4624]]" /f:text /rd:true /c:20

rem Всі події 4625 (невдалий вхід)
wevtutil qe Security /q:"*[System[EventID=4625]]" /f:text /rd:true /c:20
```

### Крок 4.3 Експортувати журнал для аналізу

```cmd
rem Зберегти Security журнал для офлайн аналізу
wevtutil epl Security C:\forensics_results\Security_backup.evtx
```

---

## Фаза 5 Аналіз .evtx файлів (офлайн форензіка)

У реальному розслідуванні аналітик отримує `.evtx` файли з вилученого комп'ютера та аналізує їх окремо — без запуску оригінальної системи.

### Крок 5.1 Відкрити .evtx файл через Event Viewer (Windows)

1. Відкрий **Event Viewer**: Win+R → `eventvwr.msc` → Enter
2. У лівій панелі: **Action → Open Saved Log...**
3. Вибери `.evtx` файл (наприклад `Security.evtx`)
4. Журнал відкриється як звичайний — можна фільтрувати та аналізувати

### Крок 5.2 Відкрити .evtx файл через FullEventLogView (Windows)

1. Запусти `FullEventLogView.exe`
2. **Options → Advanced Options → Log Source → Load events from external folder/file**
3. Вкажи шлях до `.evtx` файлу
4. Застосуй фільтри за Event ID як у Фазі 1

### Крок 5.3 Експортувати події у CSV для аналізу (Windows)

```powershell
# Завантажити події з файлу та зберегти в CSV
Get-WinEvent -Path "C:\forensics_results\Security_backup.evtx" |
    Where-Object { $_.Id -in 4624,4625,4688 } |
    Select-Object TimeCreated, Id, Message |
    Export-Csv "C:\forensics_results\offline_analysis.csv" -Encoding UTF8

Write-Host "Готово — відкрий файл у Excel для аналізу"
```

> Це дозволяє аналізувати журнали з **будь-якого** комп'ютера — навіть вимкненого чи скомпрометованого.

---

### Додатково — Аналіз на Linux (для просунутих)

> 📌 **Опціонально** — виконується якщо є доступ до Linux станції. У реальному SOC аналітики часто використовують Linux для автоматизованого парсингу великої кількості .evtx файлів.

#### Встановлення інструментів

```bash
# Створити віртуальне середовище (безпечний спосіб)
python3 -m venv evtx-env
source evtx-env/bin/activate
pip install python-evtx
```

#### Аналіз .evtx файлу

```bash
# Конвертувати evtx в XML
python3 -m evtx Security.evtx > Security.xml

# Знайти всі Event ID 4624
grep -A5 "<EventID>4624</EventID>" Security.xml | head -50

# Знайти невдалі входи 4625
grep -A5 "<EventID>4625</EventID>" Security.xml | head -50

# Порахувати кількість кожного Event ID
grep "<EventID>" Security.xml | sort | uniq -c | sort -rn | head -20
```

---

## Фаза 6 Практичний сценарій розслідування

### Сценарій: Виявлення підозрілої активності

Уяви що ти SOC-аналітик і отримав алерт о 03:15. Проаналізуй журнали та відповідай:

```
ЗАВДАННЯ:
1. Знайди всі входи між 00:00 та 06:00 за останній тиждень
   (нічні входи підозрілі для офісного ПК)

2. Знайди входи з Logon Type = 10 (RDP)
   Хто та коли підключався віддалено?

3. Знайди події 4625 кластерами
   (3+ невдалих спроби за 1 хвилину = brute force)

4. Перевір чи є події 4698
   (створення scheduled task = метод закріплення)

5. Склади хронологію підозрілих подій
```

---

## Фаза 7 Збереження результатів

```powershell
New-Item -ItemType Directory -Path C:\forensics_results -Force

# Зберегти всі знайдені входи
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624} |
    Select-Object TimeCreated, Id, Message |
    Export-Csv C:\forensics_results\logons_4624.csv -Encoding UTF8

# Зберегти невдалі спроби
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} |
    Select-Object TimeCreated, Id, Message |
    Export-Csv C:\forensics_results\failed_logons_4625.csv -Encoding UTF8

Write-Host "Збережено в C:\forensics_results\"
```

### Написати висновок

```
АНАЛІЗ WINDOWS EVENT LOG
==========================
Дата:       [сьогоднішня дата]
Студент:    [твоє ім'я]
Система:    Windows [версія]

Проаналізовано журналів: Security, System
Діапазон дат: [від] до [до]

Знайдені події:
- 4624 (успішні входи):    [N]
- 4625 (невдалі входи):    [N]
- 4688 (нові процеси):     [N]
- Підозрілих патернів:     [N]

Висновок:
Event Log є критичним артефактом для розслідування.
Дозволяє відновити хронологію дій, виявити аномалії
та знайти докази несанкціонованого доступу.
```

---

## Ключові поняття

| Термін | Пояснення |
|---|---|
| **EVTX** | Формат файлу Windows Event Log (бінарний XML) |
| **Event ID** | Унікальний номер типу події |
| **Logon Type** | Спосіб входу (консоль, мережа, RDP тощо) |
| **Security log** | Головний журнал для форензіки — всі події безпеки |
| **Audit Policy** | Налаштування що саме Windows записує в журнал |
| **Log rotation** | Автоматичне перезаписування старих записів |

---

## Автоматизація — PowerShell скрипт для SC13

> 💡 **Для викладачів та просунутих студентів.** Скрипт автоматично виконує всі кроки лаби: збирає події, виявляє підозрілі патерни (brute force, нічні входи, RDP), зберігає CSV файли та текстовий звіт. Корисно при перевірці **багатьох ПК** одночасно. Запускати від імені **Адміністратора**.

```powershell
# SC13_EventLog_Forensics.ps1
# Запускати від імені Адміністратора

$OutputDir = "C:\forensics_results\SC13"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$Report = "$OutputDir\eventlog_report.txt"

function Write-Report { param($Text) $Text | Out-File $Report -Append -Encoding UTF8 }

Write-Report ("=" * 55)
Write-Report "АНАЛІЗ WINDOWS EVENT LOG — SC13"
Write-Report "Дата:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Report "Система:  $env:COMPUTERNAME"
Write-Report ("=" * 55)

# --- 1. Успішні входи 4624 ---
Write-Report "`n--- УСПІШНІ ВХОДИ (4624) ---"
$logins = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624} -MaxEvents 100 -ErrorAction SilentlyContinue
Write-Report "Знайдено: $($logins.Count) записів (останні 100)"
if ($logins) {
    $logins | Select-Object TimeCreated,
        @{N='Account';E={$_.Properties[5].Value}},
        @{N='LogonType';E={$_.Properties[8].Value}},
        @{N='WorkStation';E={$_.Properties[11].Value}},
        @{N='IP';E={$_.Properties[18].Value}} |
        Export-Csv "$OutputDir\logons_4624.csv" -Encoding UTF8 -NoTypeInformation
    Write-Report "CSV збережено: logons_4624.csv"
}

# --- 2. Невдалі входи 4625 ---
Write-Report "`n--- НЕВДАЛІ ВХОДИ (4625) ---"
$failed = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4625} -MaxEvents 200 -ErrorAction SilentlyContinue
Write-Report "Знайдено: $($failed.Count) записів"
if ($failed) {
    $failed | Select-Object TimeCreated,
        @{N='Account';E={$_.Properties[5].Value}},
        @{N='FailureReason';E={$_.Properties[9].Value}} |
        Export-Csv "$OutputDir\failed_logons_4625.csv" -Encoding UTF8 -NoTypeInformation
    Write-Report "CSV збережено: failed_logons_4625.csv"
}

# --- 3. Виявлення Brute Force ---
Write-Report "`n--- ВИЯВЛЕННЯ BRUTE FORCE ---"
if ($failed) {
    $clusters = $failed | Group-Object { $_.TimeCreated.ToString("yyyy-MM-dd HH:mm") } |
        Where-Object { $_.Count -ge 3 }
    if ($clusters) {
        Write-Report "!!! ПІДОЗРІЛО: Виявлено кластери невдалих входів:"
        $clusters | ForEach-Object { Write-Report "  $($_.Name) — $($_.Count) спроб за 1 хвилину" }
    } else {
        Write-Report "Brute force патернів не виявлено"
    }
}

# --- 4. Нічні входи (00:00–06:00) ---
Write-Report "`n--- НІЧНІ ВХОДИ (00:00-06:00) ---"
if ($logins) {
    $night = $logins | Where-Object { $_.TimeCreated.Hour -ge 0 -and $_.TimeCreated.Hour -lt 6 }
    if ($night) {
        Write-Report "!!! ПІДОЗРІЛО: Виявлено $($night.Count) нічних входів:"
        $night | ForEach-Object {
            Write-Report "  $($_.TimeCreated)  Акаунт: $($_.Properties[5].Value)"
        }
    } else { Write-Report "Нічних входів не виявлено" }
}

# --- 5. RDP входи (LogonType=10) ---
Write-Report "`n--- RDP ВХОДИ (LogonType=10) ---"
if ($logins) {
    $rdp = $logins | Where-Object { $_.Properties[8].Value -eq 10 }
    Write-Report "Знайдено RDP входів: $($rdp.Count)"
    $rdp | ForEach-Object {
        Write-Report "  $($_.TimeCreated)  Акаунт: $($_.Properties[5].Value)  IP: $($_.Properties[18].Value)"
    }
}

# --- 6. Нові процеси 4688 ---
Write-Report "`n--- НОВІ ПРОЦЕСИ (4688) ---"
$procs = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4688} -MaxEvents 50 -ErrorAction SilentlyContinue
Write-Report "Знайдено: $($procs.Count) записів (останні 50)"
if ($procs) {
    $procs | Select-Object TimeCreated,
        @{N='Process';E={$_.Properties[5].Value}},
        @{N='ParentProcess';E={$_.Properties[13].Value}} |
        Export-Csv "$OutputDir\processes_4688.csv" -Encoding UTF8 -NoTypeInformation
    Write-Report "CSV збережено: processes_4688.csv"
}

# --- 7. Scheduled Tasks 4698 ---
Write-Report "`n--- НОВІ SCHEDULED TASKS (4698) ---"
$tasks = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4698} -ErrorAction SilentlyContinue
if ($tasks) {
    Write-Report "!!! Знайдено $($tasks.Count) нових scheduled task(s) — перевір на закріплення зловмисника!"
    $tasks | ForEach-Object { Write-Report "  $($_.TimeCreated)  $($_.Message.Substring(0,[Math]::Min(120,$_.Message.Length)))" }
} else { Write-Report "Нових scheduled tasks не виявлено" }

# --- 8. Нові облікові записи 4720 ---
Write-Report "`n--- НОВІ ОБЛІКОВІ ЗАПИСИ (4720) ---"
$accounts = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4720} -ErrorAction SilentlyContinue
if ($accounts) {
    Write-Report "!!! Знайдено $($accounts.Count) нових облікових записів — можливий backdoor user!"
    $accounts | ForEach-Object { Write-Report "  $($_.TimeCreated)  $($_.Properties[0].Value)" }
} else { Write-Report "Нових облікових записів не виявлено" }

# --- Підсумок ---
Write-Report "`n--- ПІДСУМОК ---"
Write-Report "4624 (успішні входи):   $($logins.Count)"
Write-Report "4625 (невдалі входи):   $($failed.Count)"
Write-Report "4688 (нові процеси):    $($procs.Count)"
Write-Report "4698 (scheduled tasks): $($tasks.Count)"
Write-Report "4720 (нові акаунти):    $($accounts.Count)"
Write-Report "Звіт збережено: $Report"

Write-Host "`nГотово! Результати: $OutputDir" -ForegroundColor Green
Invoke-Item $OutputDir
```

**Як запустити:**
```powershell
# У PowerShell від імені Адміністратора:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SC13_EventLog_Forensics.ps1
```

---

## Чеклист для самоперевірки

```
[ ] FullEventLogView встановлено та запущено
[ ] Security журнал відфільтровано
[ ] Event ID 4624 знайдено та проаналізовано
[ ] Event ID 4625 знайдено та проаналізовано
[ ] PowerShell запити виконано
[ ] wevtutil команди виконано
[ ] Офлайн .evtx файл відкрито через Event Viewer або FullEventLogView
[ ] CSV експорт через PowerShell виконано
[ ] Таблиця ключових Event ID заповнена
[ ] Практичний сценарій виконано
[ ] Результати збережено в CSV
[ ] Висновок написано
```

---

*ITS/КСЗІ — Event Log Forensics Lab | Сценарій 13 | ТІЛЬКИ ДЛЯ НАВЧАННЯ | SET University*
