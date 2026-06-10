# Лабораторна робота — Сценарій 12: Аналіз артефактів облікових даних Windows

Назва лабораторної: Windows Credentials Forensics — Credential Artifacts Analysis
Модуль: Цифрова криміналістика / Windows Artifacts
Сценарій: 12  Credential Artifacts Analysis
Формат: Self-Paced
Версія документу: 1.0

---

## Мета

Навчитися виявляти та аналізувати артефакти облікових даних у Windows з форензік-перспективи. Зрозуміти де Windows зберігає інформацію про автентифікацію та як ці артефакти використовуються при розслідуванні інцидентів.

---

## Теоретична частина

### Де Windows зберігає артефакти облікових даних

При цифровому розслідуванні аналітик шукає артефакти автентифікації щоб відновити хронологію дій та визначити рівень доступу підозрюваного. Windows зберігає такі артефакти у кількох місцях:

| Артефакт | Розташування | Вміст |
|---|---|---|
| Windows Credential Manager | `%APPDATA%\Microsoft\Credentials\` | Збережені паролі до сайтів та мереж |
| SAM база даних | `C:\Windows\System32\config\SAM` | Хеші паролів локальних користувачів |
| LSASS пам'ять | Процес lsass.exe | Активні сесії (аналіз дампу) |
| NTDS.dit | `C:\Windows\NTDS\` | База AD (на контролерах домену) |
| Prefetch | `C:\Windows\Prefetch\` | Сліди запуску програм |
| Event Log | `C:\Windows\System32\winevt\` | Журнал входів (Event ID 4624, 4625) |

---

## Підготовка — Встановлення CredentialsFileView

Завантажити з офіційного сайту NirSoft:

```
https://www.nirsoft.net/utils/credentials_file_view.html
```

Розпакувати `CredentialsFileView.zip` → запустити `CredentialsFileView.exe`.

> ⚠ Деякі антивіруси можуть виявити інструменти NirSoft як потенційно небезпечні через їх форензік-природу. Це нормально для аналітичних інструментів — додай виключення в антивірус або запусти з вимкненим захистом у навчальному середовищі.

---

## Фаза 1 — Аналіз через CredentialsFileView

### Крок 1.1 — Відкрити CredentialsFileView

Запусти `CredentialsFileView.exe`. Програма автоматично знайде та відобразить артефакти Credential Manager поточного користувача.

### Крок 1.2 — Дослідити структуру артефактів

Для кожного запису заповни таблицю:

| Поле | Значення | Форензічне значення |
|---|---|---|
| Filename | | Ім'я файлу артефакту |
| Modified Time | | Коли зберігався запис |
| Target Name | | До якого ресурсу належить |
| Type | | Generic / Domain / Certificate |
| User Name | | Ім'я користувача |
| Storage Location | | Local / Enterprise / Session |

### Крок 1.3 — Форензічний аналіз

Відповідь на питання:

```
1. Скільки збережених записів знайдено?

2. Які типи записів переважають (Generic/Domain/Certificate)?

3. Чи є записи з підозріло старими або новими датами?

4. Які мережеві ресурси або сайти збережені?

5. Що означає Storage Location "Enterprise" vs "Local"?
```

---

## Фаза 2 Ручний аналіз через командний рядок

### Крок 2.1 Переглянути Credential Manager через cmdkey

```cmd
cmdkey /list
```

**Очікуваний результат:**
```
Currently stored credentials:

    Target: Domain:target=DESKTOP-PC\User
    Type: Domain Extended
    User: UserName
    ...
```

### Крок 2.2 Знайти файли артефактів вручну

```cmd
dir "%APPDATA%\Microsoft\Credentials" /a
dir "%LOCALAPPDATA%\Microsoft\Credentials" /a
```

### Крок 2.3 Переглянути через PowerShell

```powershell
# Перегляд Credential Manager
[Windows.Security.Credentials.PasswordVault, Windows.Security.Credentials, ContentType=WindowsRuntime]::new().RetrieveAll() | ForEach-Object { $_.RetrievePassword(); $_ }
```

---

## Фаза 3 Аналіз файлів артефактів через Провідник та реєстр (Windows)

### Крок 3.1 Знайти файли Credential Manager через Провідник

1. Відкрий **Провідник** (Win+E)
2. У адресному рядку введи:
```
%APPDATA%\Microsoft\Credentials
```
3. Якщо папка порожня або не відображає файли — увімкни показ прихованих файлів:
```
Вигляд → Показати → Приховані елементи ✅
```
4. Також перевір другу папку:
```
%LOCALAPPDATA%\Microsoft\Credentials
```

### Крок 3.2 Переглянути властивості файлів артефактів

Для кожного знайденого файлу — правою кнопкою → **Властивості** і запиши:

| Поле | Значення |
|---|---|
| Ім'я файлу | |
| Розмір | |
| Дата створення | |
| Дата зміни | |
| Дата відкриття | |

> Дати файлів — це форензічні мітки. Якщо файл створено посеред ночі або одразу після встановлення нової програми — це підозрілий сигнал.

### Крок 3.3 Дослідити записи реєстру, пов'язані з обліковими даними

Відкрий **regedit** (Win+R → regedit → Enter) та перейди до:

```
HKEY_CURRENT_USER\Software\Microsoft\Windows NT\CurrentVersion\Winlogon
```

Перевір значення:
- `DefaultUserName` — збережене ім'я користувача
- `DefaultPassword` — (якщо є — це небезпечно, пароль у відкритому тексті)
- `AutoAdminLogon` — автоматичний вхід увімкнено?

Також перевір:
```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Lsa
```

Запиши значення `LmCompatibilityLevel` — визначає рівень автентифікації NTLM.

### Крок 3.4 Форензічні спостереження

Відповідь на питання:

```
1. Скільки файлів знайдено в папках Credentials?

2. Які дати створення файлів (підозріло нові чи старі)?

3. Чи є значення DefaultPassword у реєстрі?
   Якщо так — це знахідка форензіки, запиши це!

4. Яке значення LmCompatibilityLevel?
   (0-2 = слабкий NTLM, 3-5 = NTLMv2, 5 = тільки NTLMv2)
```

---

## Фаза 4 Форензічна цінність артефактів

### Що шукають слідчі:

| Сценарій розслідування | Що аналізують |
|---|---|
| Несанкціонований доступ | Нові записи в Credential Manager після інциденту |
| Insider threat | Збережені дані до корпоративних ресурсів |
| Malware | Записи C2 доменів або підозрілих сайтів |
| Горизонтальне переміщення | Збережені дані до інших хостів мережі |

### MITRE ATT&CK відображення:

| Техніка | ID | Де шукати |
|---|---|---|
| Credentials from Password Stores | T1555.004 | Windows Credential Manager |
| OS Credential Dumping | T1003 | SAM, LSASS, NTDS.dit |
| Steal Web Session Cookie | T1539 | Browser credential stores |

---

## Фаза 5 Збереження результатів

```cmd
mkdir C:\forensics_results

rem Зберегти список через cmdkey
cmdkey /list > C:\forensics_results\credential_list.txt

rem Зберегти деталі через CredentialsFileView
rem File → Save As → C:\forensics_results\credentials_report.csv
```

### Написати висновок:

```
АНАЛІЗ АРТЕФАКТІВ ОБЛІКОВИХ ДАНИХ
====================================
Дата:      [сьогоднішня дата]
Студент:   [твоє ім'я]
Система:   Windows [версія]

Знайдено записів: [N]
Типи: Generic=[N], Domain=[N], Certificate=[N]

Форензічна цінність:
Credential Manager зберігає артефакти автентифікації
які допомагають слідчим встановити до яких ресурсів
мав доступ користувач та коли. Ці артефакти є важливими
доказами при розслідуванні інцидентів безпеки.
```

---

## Автоматизація — PowerShell скрипт для SC12

> 💡 **Для викладачів та просунутих студентів.** Якщо потрібно перевірити багато комп'ютерів одночасно — цей скрипт виконує всі кроки лаби автоматично і зберігає звіт у файл. Запускати від імені **Адміністратора**.

```powershell
# SC12_Credentials_Forensics.ps1
# Запускати від імені Адміністратора

$OutputDir = "C:\forensics_results\SC12"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$Report = "$OutputDir\credentials_report.txt"

function Write-Report { param($Text) $Text | Out-File $Report -Append -Encoding UTF8 }

Write-Report ("=" * 55)
Write-Report "АНАЛІЗ АРТЕФАКТІВ ОБЛІКОВИХ ДАНИХ — SC12"
Write-Report "Дата:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Report "Система:  $env:COMPUTERNAME"
Write-Report "Користувач: $env:USERNAME"
Write-Report ("=" * 55)

# --- 1. Credential Manager через cmdkey ---
Write-Report "`n--- CREDENTIAL MANAGER (cmdkey /list) ---"
cmdkey /list | Out-File $Report -Append -Encoding UTF8

# --- 2. Файли артефактів ---
Write-Report "`n--- ФАЙЛИ АРТЕФАКТІВ ---"
@("$env:APPDATA\Microsoft\Credentials", "$env:LOCALAPPDATA\Microsoft\Credentials") | ForEach-Object {
    Write-Report "`nПапка: $_"
    if (Test-Path $_) {
        $files = Get-ChildItem $_ -Force
        if ($files) {
            $files | ForEach-Object {
                Write-Report "  Файл:     $($_.Name)"
                Write-Report "  Розмір:   $($_.Length) байт"
                Write-Report "  Створено: $($_.CreationTime)"
                Write-Report "  Змінено:  $($_.LastWriteTime)"
                Write-Report "  ---"
            }
        } else { Write-Report "  Файлів не знайдено" }
    } else { Write-Report "  Папка не існує" }
}

# --- 3. Реєстр: Winlogon ---
Write-Report "`n--- РЕЄСТР: WINLOGON ---"
$wl = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction SilentlyContinue
Write-Report "DefaultUserName:  $($wl.DefaultUserName)"
Write-Report "AutoAdminLogon:   $($wl.AutoAdminLogon)"
if ($wl.DefaultPassword) {
    Write-Report "!!! ЗНАХІДКА: DefaultPassword існує — пароль у відкритому тексті в реєстрі!"
} else {
    Write-Report "DefaultPassword:  не знайдено (норма)"
}

# --- 4. Реєстр: LSA ---
Write-Report "`n--- РЕЄСТР: LSA ---"
$lsa = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -ErrorAction SilentlyContinue
$level = $lsa.LmCompatibilityLevel
$levelDesc = switch ($level) {
    0 { "Слабкий — LM та NTLM" }
    1 { "Слабкий — LM та NTLMv2" }
    2 { "Середній — тільки NTLM" }
    3 { "Рекомендований — тільки NTLMv2" }
    4 { "Сильний — NTLMv2, відхиляти LM" }
    5 { "Максимальний — тільки NTLMv2, відхиляти LM та NTLM" }
    default { "Невідомо" }
}
Write-Report "LmCompatibilityLevel: $level — $levelDesc"

# --- Підсумок ---
Write-Report "`n--- ПІДСУМОК ---"
Write-Report "Звіт збережено: $Report"

Write-Host "`nГотово! Результати: $OutputDir" -ForegroundColor Green
Invoke-Item $OutputDir
```

**Як запустити:**
```powershell
# У PowerShell від імені Адміністратора:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\SC12_Credentials_Forensics.ps1
```

---

## Чеклист для самоперевірки

```
[ ] CredentialsFileView встановлено та запущено
[ ] Записи проаналізовано та задокументовано
[ ] cmdkey /list виконано
[ ] Файли в %APPDATA%\Microsoft\Credentials знайдено та досліджено
[ ] Властивості файлів (дати) записано
[ ] Реєстр перевірено (Winlogon, LSA)
[ ] Форензічна цінність артефактів пояснена
[ ] Відображення на MITRE ATT&CK виконано
[ ] Висновок написано
```

---

*ITS/КСЗІ — Credentials Forensics Lab | Сценарій 12 | ТІЛЬКИ ДЛЯ НАВЧАННЯ | SET University*
