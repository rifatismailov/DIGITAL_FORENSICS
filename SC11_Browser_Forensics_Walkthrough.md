# Лабораторна робота — Сценарій 11: Аналіз історії браузерів

Назва лабораторної: Browser Forensics — Browsing History Analysis
Модуль: Цифрова криміналістика / Аналіз артефактів браузера
Сценарій: 11 — Browser History Analysis
Формат: Self-Paced
Версія документу: 1.0

---

## Мета

Навчитися знаходити та аналізувати артефакти браузерів (Chrome, Firefox, Edge) на локальній машині. Зрозуміти де зберігаються дані браузера та як їх аналізувати форензік-інструментами.

---

## Середовище та інструментарій

| Інструмент | Платформа | Призначення |
|---|---|---|
| **sqlite3** | Windows + Linux | Прямий аналіз баз даних браузера |
| **Hindsight** | Windows + Linux | Комплексний аналіз Chrome/Edge |
| **BrowsingHistoryView** | Windows | GUI аналіз всіх браузерів |

---

## Частина А — Windows

### Підготовка — Встановлення інструментів

**Варіант 1: BrowsingHistoryView (GUI, простіший)**

Завантажити з:
```
https://www.nirsoft.net/utils/browsing_history_view.html
```

Розпакувати `.zip` → запустити `BrowsingHistoryView.exe` — реєстрація не потрібна.

**Варіант 2: Hindsight (кросплатформений)**

```powershell
pip install hindsight
```

**Варіант 3: sqlite3 (вбудований)**

Завантажити з:
```
https://sqlite.org/download.html
```
→ sqlite-tools-win-x64 → розпакувати.

---

### Фаза 1 — Знайти файли браузера

#### Chrome / Edge / Brave

Відкрий **Провідник** та перейди:

```
# Chrome
C:\Users\[ім'я]\AppData\Local\Google\Chrome\User Data\Default\

# Edge
C:\Users\[ім'я]\AppData\Local\Microsoft\Edge\User Data\Default\

# Brave
C:\Users\[ім'я]\AppData\Local\BraveSoftware\Brave-Browser\User Data\Default\
```

**Ключові файли:**

| Файл | Вміст |
|---|---|
| `History` | Відвідані сайти (SQLite) |
| `Cookies` | Cookies (SQLite) |
| `Login Data` | Збережені паролі (SQLite, зашифровані) |
| `Bookmarks` | Закладки (JSON) |
| `Cache\` | Кешовані файли |

#### Firefox

```
C:\Users\[ім'я]\AppData\Roaming\Mozilla\Firefox\Profiles\[профіль]\
```

**Ключові файли:**

| Файл | Вміст |
|---|---|
| `places.sqlite` | Історія + закладки |
| `cookies.sqlite` | Cookies |
| `formhistory.sqlite` | Форми автозаповнення |
| `logins.json` | Збережені паролі |

---

### Фаза 2 — Аналіз через BrowsingHistoryView (GUI)

1. Запусти `BrowsingHistoryView.exe`
2. Програма автоматично знайде всі браузери на ПК
3. Переглянь список відвіданих сайтів

**Що шукати:**

| Колонка | Значення |
|---|---|
| URL | Адреса відвіданої сторінки |
| Title | Назва сторінки |
| Visit Time | Час відвідування |
| Visit Count | Кількість відвідувань |
| Browser | Який браузер |

**Зберегти звіт:**
```
Файл → Зберегти як CSV
View → Save Selected Items → browsing_report.csv
```

---

### Фаза 3 — Прямий аналіз через sqlite3 (Windows)

#### Chrome History

```powershell
# Скопіювати файл (браузер має бути закритий)
copy "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\History" C:\Temp\chrome_history

# Відкрити в sqlite3
cd C:\Temp
sqlite3.exe chrome_history
```

**Запити всередині sqlite3:**

```sql
-- Переглянути таблиці
.tables

-- Останні 20 відвідувань
SELECT url, title, datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime')
AS visit_time
FROM urls
ORDER BY last_visit_time DESC
LIMIT 20;

-- Топ 10 найчастіше відвідуваних сайтів
SELECT url, title, visit_count
FROM urls
ORDER BY visit_count DESC
LIMIT 10;

-- Пошук за ключовим словом
SELECT url, title, visit_count
FROM urls
WHERE url LIKE '%google%'
ORDER BY last_visit_time DESC;

-- Вийти
.quit
```

#### Firefox History

```powershell
copy "$env:APPDATA\Mozilla\Firefox\Profiles\*.default*\places.sqlite" C:\Temp\firefox_history

sqlite3.exe C:\Temp\firefox_history
```

```sql
-- Останні 20 відвідувань
SELECT url, title, datetime(last_visit_date/1000000,'unixepoch','localtime') AS visit_time
FROM moz_places
WHERE last_visit_date IS NOT NULL
ORDER BY last_visit_date DESC
LIMIT 20;

-- Топ сайти
SELECT url, title, visit_count
FROM moz_places
ORDER BY visit_count DESC
LIMIT 10;

.quit
```

---

### Фаза 4 — Аналіз через Hindsight (Windows)

```powershell
# Встановити
pip install hindsight

# Аналіз Chrome
python -m hindsight -i "C:\Users\[ім'я]\AppData\Local\Google\Chrome\User Data\Default" -o C:\Temp\chrome_report

# Відкрити HTML звіт
start C:\Temp\chrome_report.html
```

Hindsight генерує детальний HTML звіт з усіма артефактами.

---

## Частина Б — Linux (Ubuntu)

### Фаза 1 — Знайти файли браузера

```bash
# Chrome
ls ~/.config/google-chrome/Default/

# Chromium
ls ~/.config/chromium/Default/

# Firefox
ls ~/.mozilla/firefox/*.default*/

# Brave
ls ~/.config/BraveSoftware/Brave-Browser/Default/
```

**Ключові файли:**

```bash
# Chrome/Chromium/Brave
~/.config/google-chrome/Default/History
~/.config/google-chrome/Default/Cookies
~/.config/google-chrome/Default/Bookmarks

# Firefox
~/.mozilla/firefox/*.default*/places.sqlite
~/.mozilla/firefox/*.default*/cookies.sqlite
```

---

### Фаза 2 — Аналіз через sqlite3 (Linux)

#### Chrome History

```bash
# Закрити Chrome перед аналізом
# Скопіювати файл
cp ~/.config/google-chrome/Default/History /tmp/chrome_history

# Відкрити
sqlite3 /tmp/chrome_history
```

```sql
-- Таблиці
.tables

-- Останні 20 відвідувань
SELECT url, title,
       datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime') AS visit_time
FROM urls
ORDER BY last_visit_time DESC
LIMIT 20;

-- Топ 10 сайтів
SELECT url, title, visit_count
FROM urls
ORDER BY visit_count DESC
LIMIT 10;

-- Пошук
SELECT url, title
FROM urls
WHERE url LIKE '%github%'
ORDER BY last_visit_time DESC;

.quit
```

#### Firefox History

```bash
# Знайти профіль Firefox
ls ~/.mozilla/firefox/

# Скопіювати базу
cp ~/.mozilla/firefox/*.default*/places.sqlite /tmp/firefox_history

sqlite3 /tmp/firefox_history
```

```sql
SELECT url, title,
       datetime(last_visit_date/1000000,'unixepoch','localtime') AS visit_time
FROM moz_places
WHERE last_visit_date IS NOT NULL
ORDER BY last_visit_date DESC
LIMIT 20;

.quit
```

---

### Фаза 3 — Hindsight (Linux)

```bash
# Встановити
pip3 install hindsight --break-system-packages

# Аналіз Chrome
python3 -m hindsight \
    -i ~/.config/google-chrome/Default \
    -o ~/hindsight_report

# Переглянути звіт
ls ~/hindsight_report/
```

---

## Фаза 5 — Завдання для аналізу (обидві платформи)

Відповідай на питання на основі своїх даних:

```
1. Скільки унікальних сайтів у твоїй історії?

2. Який сайт ти відвідуєш найчастіше (Top-1)?

3. Знайди всі відвідування за останні 7 днів.

4. Чи є в історії відвідування через приватний режим?
   (Підказка: приватний режим НЕ зберігається в History)

5. Яка різниця між visit_count та кількістю записів
   у таблиці visits?
```

---

## Фаза 6 — Збереження результатів

### Windows

```powershell
mkdir C:\Temp\browser_forensics

# CSV з BrowsingHistoryView
# Збережи через File → Save As CSV

# Збережи SQL запити
sqlite3.exe chrome_history ".output C:\Temp\browser_forensics\top10.txt" "SELECT url,visit_count FROM urls ORDER BY visit_count DESC LIMIT 10;"
```

### Linux

```bash
mkdir ~/browser_forensics

sqlite3 /tmp/chrome_history \
    "SELECT url, title, visit_count FROM urls ORDER BY visit_count DESC LIMIT 10;" \
    > ~/browser_forensics/top10_sites.txt

sqlite3 /tmp/chrome_history \
    "SELECT url, datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime') FROM urls ORDER BY last_visit_time DESC LIMIT 20;" \
    > ~/browser_forensics/recent_history.txt

echo "Збережено:"
ls -lh ~/browser_forensics/
```

### Написати висновок

```
АНАЛІЗ БРАУЗЕРА: Chrome / Firefox / Edge
==========================================
Дата:      [сьогоднішня дата]
Студент:   [твоє ім'я]
Браузер:   [який аналізував]

Статистика:
- Унікальних сайтів: [N]
- Топ-1 сайт: [URL]
- Діапазон дат: [від] до [до]

Форензічна цінність:
Артефакти браузера дозволяють відновити хронологію
дій користувача в мережі. В реальному розслідуванні
це допомагає встановити мотив, контакти підозрюваного
та часові рамки інциденту.
```

---

## Ключові поняття

| Термін | Пояснення |
|---|---|
| **SQLite** | Легка база даних у одному файлі — використовується всіма браузерами |
| **UNIX timestamp** | Час в секундах від 01.01.1970 — потребує конвертації |
| **Chrome time** | Мікросекунди від 01.01.1601 — особливий формат Chrome |
| **visit_count** | Кількість відвідувань конкретного URL |
| **places.sqlite** | Головна база Firefox — містить і історію і закладки |
| **Приватний режим** | Не залишає записів в History файлі |

---

## Чеклист для самоперевірки

```
[ ] Знайдено файл History браузера
[ ] Файл скопійовано для аналізу (браузер закрито)
[ ] sqlite3 запущено успішно
[ ] Виконано запит на останні 20 відвідувань
[ ] Виконано запит на топ 10 сайтів
[ ] Виконано пошук за ключовим словом
[ ] Результати збережено у файл
[ ] Написано висновок
```

---

*ITS/КСЗІ — Browser Forensics Lab | Сценарій 11 | ТІЛЬКИ ДЛЯ НАВЧАННЯ | SET University*
