# Лабораторна робота — Сценарій 13: Аналіз Windows Event Log

Назва лабораторної: Windows Event Log Forensics — Security Event Analysis
Модуль: Цифрова криміналістика / Windows Artifacts
Сценарій: 13 — Windows Event Log Analysis
Формат: Self-Paced
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

## Підготовка — Встановлення FullEventLogView

Завантажити з офіційного сайту NirSoft:

```
https://www.nirsoft.net/utils/full_event_log_view.html
```

Розпакувати → запустити `FullEventLogView.exe`.

---

## Фаза 1 — Аналіз через FullEventLogView

### Крок 1.1 — Відкрити FullEventLogView

Запусти `FullEventLogView.exe`. Програма завантажить всі журнали поточної системи.

### Крок 1.2 — Фільтрація за Security журналом

```
Options → Advanced Options → Log Source → Security
```

Або використай фільтр:
```
View → Use Custom Filter → Channel: Security
```

### Крок 1.3 — Знайти події входу (Event ID 4624)

У полі фільтру встанови:
```
Event ID: 4624
```

Для кожного запису запиши:

| Час | Event ID | Logon Type | Account Name | Workstation |
|---|---|---|---|---|
| | 4624 | | | |
| | 4624 | | | |

### Крок 1.4 — Знайти невдалі спроби входу (Event ID 4625)

```
Event ID: 4625
```

**Підозрілий патерн:** багато 4625 підряд = можлива brute force атака.

### Крок 1.5 — Зберегти результати

```
File → Save Selected Items → security_events.csv
```

---

## Фаза 2 — Аналіз через вбудований Event Viewer (Windows)

### Крок 2.1 — Відкрити Event Viewer

```
Win+R → eventvwr.msc → Enter
```

### Крок 2.2 — Створити Custom View для розслідування

```
Action → Create Custom View
    Logged: Last 7 days
    Event Level: ✅ Critical ✅ Error ✅ Warning
    By log: Windows Logs → Security
    Event IDs: 4624,4625,4648,4688,4698,4720,7045
```

### Крок 2.3 — Аналіз підозрілих подій

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

## Фаза 3 — Аналіз через PowerShell (Windows)

### Крок 3.1 — Отримати останні події безпеки

```powershell
# Останні 50 подій безпеки
Get-EventLog -LogName Security -Newest 50 | Format-Table TimeGenerated, EventID, Message -AutoSize
```

### Крок 3.2 — Знайти всі входи за останні 24 години

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

### Крок 3.3 — Знайти невдалі спроби входу

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    Id      = 4625
} -MaxEvents 20 | Select-Object TimeCreated,
    @{N='Account';E={$_.Properties[5].Value}},
    @{N='FailureReason';E={$_.Properties[9].Value}} |
    Format-Table -AutoSize
```

### Крок 3.4 — Пошук підозрілих процесів (4688)

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

## Фаза 4 — Аналіз через wevtutil (командний рядок)

### Крок 4.1 — Базові команди

```cmd
rem Список журналів
wevtutil el

rem Інформація про журнал Security
wevtutil gl Security

rem Останні 10 подій з Security
wevtutil qe Security /c:10 /rd:true /f:text
```

### Крок 4.2 — Фільтрація за Event ID

```cmd
rem Всі події 4624 (успішний вхід)
wevtutil qe Security /q:"*[System[EventID=4624]]" /f:text /rd:true /c:20

rem Всі події 4625 (невдалий вхід)
wevtutil qe Security /q:"*[System[EventID=4625]]" /f:text /rd:true /c:20
```

### Крок 4.3 — Експортувати журнал для аналізу

```cmd
rem Зберегти Security журнал для офлайн аналізу
wevtutil epl Security C:\forensics_results\Security_backup.evtx
```

---

## Фаза 5 — Аналіз на Linux (форензіка .evtx файлів)

У реальному розслідуванні аналітик отримує `.evtx` файли з вилученого комп'ютера та аналізує їх на своїй Linux станції.

### Встановлення інструментів

```bash
sudo apt install python3-evtx -y
pip3 install python-evtx --break-system-packages
```

### Аналіз .evtx файлу

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

## Фаза 6 — Практичний сценарій розслідування

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

## Фаза 7 — Збереження результатів

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

## Чеклист для самоперевірки

```
[ ] FullEventLogView встановлено та запущено
[ ] Security журнал відфільтровано
[ ] Event ID 4624 знайдено та проаналізовано
[ ] Event ID 4625 знайдено та проаналізовано
[ ] PowerShell запити виконано
[ ] wevtutil команди виконано
[ ] Таблиця ключових Event ID заповнена
[ ] Практичний сценарій виконано
[ ] Результати збережено в CSV
[ ] Висновок написано
```

---

*ITS/КСЗІ — Event Log Forensics Lab | Сценарій 13 | ТІЛЬКИ ДЛЯ НАВЧАННЯ | SET University*
