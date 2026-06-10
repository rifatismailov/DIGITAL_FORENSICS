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

## Фаза 3 Аналіз артефактів на Linux (форензіка образів)

У реальному розслідуванні аналітик працює з **образом диска** — не з живою системою. На Ubuntu:

```bash
# Знайти файли Credential Manager в образі Windows
find /mnt/windows_image/Users/*/AppData/Roaming/Microsoft/Credentials/ -type f 2>/dev/null

# Визначити тип файлів
file /mnt/windows_image/Users/*/AppData/Roaming/Microsoft/Credentials/*

# Переглянути метадані файлів
stat /mnt/windows_image/Users/*/AppData/Roaming/Microsoft/Credentials/*
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

## Чеклист для самоперевірки

```
[ ] CredentialsFileView встановлено та запущено
[ ] Записи проаналізовано та задокументовано
[ ] cmdkey /list виконано
[ ] Форензічна цінність артефактів пояснена
[ ] Відображення на MITRE ATT&CK виконано
[ ] Висновок написано
```

---

*ITS/КСЗІ — Credentials Forensics Lab | Сценарій 12 | ТІЛЬКИ ДЛЯ НАВЧАННЯ | SET University*
