# Лабораторна робота: Аналіз документу з макросом

Назва лабораторної: Macro Document Analysis — Excel VBA Forensics
Модуль: Аналіз шкідливих документів / Цифрова форензіка
Сценарій: 06 (розширення)
Формат: Self-Paced
Версія документу: 1.0

---

## Мета

Навчитися виявляти та аналізувати macro-enabled документи Microsoft Excel за допомогою інструментів командного рядка Ubuntu. Зрозуміти структуру XLSM файлів та методи виявлення VBA-коду.

---

## Підготовка

Перевірити що інструменти доступні:

```bash
oleid --help 2>&1 | head -2
olevba --help 2>&1 | head -2
```

Перевірити наявність файлу:

```bash
ls -lh ~/scenario/invoice_INV-2024-0847.xlsm
```

---

## Фаза 1 — Ідентифікація файлу

### Крок 1.1 — Визначити тип файлу

```bash
file ~/scenario/invoice_INV-2024-0847.xlsm
```

**Очікуваний результат:**
```
/home/studentN/scenario/invoice_INV-2024-0847.xlsm: Microsoft Excel 2007+
```

**Що означає:** файл є OOXML форматом (ZIP + XML). Розширення `.xlsm` = macro-enabled.

### Крок 1.2 — Переглянути внутрішню структуру

```bash
unzip -l ~/scenario/invoice_INV-2024-0847.xlsm
```

**Очікуваний результат:**
```
Archive:  invoice_INV-2024-0847.xlsm
  Length      Date    Time    Name
---------  ---------- -----   ----
      628             [Content_Types].xml
      240             _rels/.rels
      294             xl/workbook.xml
      504             xl/_rels/workbook.xml.rels
      329             xl/worksheets/sheet1.xml
      101             xl/worksheets/sheet2.xml
     7680             xl/vbaProject.bin     ← ПІДОЗРІЛО
```

** IOC:** наявність `vbaProject.bin` = файл містить VBA макроси.

### Крок 1.3 — Переглянути workbook.xml

```bash
unzip -p ~/scenario/invoice_INV-2024-0847.xlsm xl/workbook.xml
```

**Що шукати:**
```xml
<sheet name="CdnApi" state="veryHidden"/>
```

** IOC:** `state="veryHidden"` — аркуш прихований навіть від меню Excel. Зловмисники ховають macro код у прихованих аркушах.

---

## Фаза 2 — Аналіз через oleid

### Крок 2.1 — Запустити oleid

```bash
oleid ~/scenario/invoice_INV-2024-0847.xlsm
```

**Очікуваний результат:**
```
Filename: invoice_INV-2024-0847.xlsm
--------------------+--------------------+----------+
Indicator           |Value               |Risk      |
--------------------+--------------------+----------+
File format         |MS Excel 2007+      |info      |
                    |Macro-Enabled       |          |
Container format    |OpenXML             |info      |
Encrypted           |False               |none      |
VBA Macros          |No                  |none      |
```

**Що означають індикатори:**

| Індикатор | Значення |
|---|---|
| File format: Macro-Enabled | XLSM — файл підтримує макроси |
| Encrypted: False | Не зашифровано — можна аналізувати |
| VBA Macros: No | oleid не знайшов — перевіряємо через strings |

---

## Фаза 3 — Аналіз vbaProject.bin

### Крок 3.1 — Витягнути бінарний файл

```bash
unzip -p ~/scenario/invoice_INV-2024-0847.xlsm xl/vbaProject.bin > ~/vbaProject.bin
```

### Крок 3.2 — Визначити тип

```bash
file ~/vbaProject.bin
```

**Очікуваний результат:**
```
/home/studentN/vbaProject.bin: Composite Document File V2 Document
```

** IOC:** `Composite Document File V2` = OLE2 Microsoft — стандартний контейнер для VBA.

### Крок 3.3 — Перевірити magic bytes

```bash
xxd ~/vbaProject.bin | head -2
```

**Очікуваний результат:**
```
00000000: d0cf 11e0 a1b1 1ae1 ...
```

**`D0 CF 11 E0`** — OLE2 magic bytes. Завжди означає Microsoft Compound Document.

---

## Фаза 4 — Пошук VBA коду через strings

### Крок 4.1 — Знайти VBA структуру

```bash
strings ~/vbaProject.bin | grep -iE "auto|sub|msgbox|module"
```

**Очікуваний результат:**
```
Attribute VB_Name = "Module1"
Sub Auto_Open()
    info = info & "Module: Module1" & Chr(10)
    info = info & "Trigger: Auto_Open()" & Chr(10)
    MsgBox info, vbInformation, "SC06 Demo"
End Sub
```

** IOC:** `Sub Auto_Open()` — **AutoExec тригер**. Запускається **автоматично** при відкритті файлу.

### Крок 4.2 — Пошук всіх читабельних рядків

```bash
strings ~/vbaProject.bin
```

### Крок 4.3 — Пошук мережевих індикаторів

```bash
strings ~/vbaProject.bin | grep -iE "http|ftp|download|shell|cmd|powershell|wscript"
```

У навчальному файлі нічого не знайде. У реально шкідливому — знайде C2 адреси та команди завантаження.

---

## Фаза 5 — Аналіз через olevba

### Крок 5.1 — Запустити olevba

```bash
olevba ~/scenario/invoice_INV-2024-0847.xlsm
```

У навчальному файлі olevba показує `No VBA found` через спрощену OLE2 структуру. Але `strings` вже підтвердив наявність VBA коду.

**Типовий вивід olevba для реального XLSM з шкідливим макросом:**
```
+----------+--------------------+---------------------------------------------+
|Type      |Keyword             |Description                                  |
+----------+--------------------+---------------------------------------------+
|AutoExec  |Auto_Open           |Runs when the Excel Workbook is opened       |
|Suspicious|Shell               |May run an executable file                   |
|Suspicious|DownloadString      |May download files from the Internet         |
|Obfuscation|Chr               |May attempt to obfuscate strings             |
+----------+--------------------+---------------------------------------------+
```

---

## Фаза 6 — Збереження результатів

### Крок 6.1 — Зберегти всі результати

```bash
mkdir -p ~/analysis_results

file ~/scenario/invoice_INV-2024-0847.xlsm    > ~/analysis_results/01_file.txt
unzip -l ~/scenario/invoice_INV-2024-0847.xlsm > ~/analysis_results/02_structure.txt
oleid ~/scenario/invoice_INV-2024-0847.xlsm   > ~/analysis_results/03_oleid.txt
strings ~/vbaProject.bin                       > ~/analysis_results/04_strings.txt
xxd ~/vbaProject.bin | head -20                > ~/analysis_results/05_hexdump.txt
unzip -p ~/scenario/invoice_INV-2024-0847.xlsm xl/workbook.xml > ~/analysis_results/06_workbook.xml

echo "Збережено:"
ls -lh ~/analysis_results/
```

### Крок 6.2 — Написати висновок

```bash
nano ~/analysis_results/conclusion.txt
```

```
АНАЛІЗ ДОКУМЕНТУ: invoice_INV-2024-0847.xlsm
==============================================
Дата аналізу:     [сьогоднішня дата]
Аналітик:         [твоє ім'я]

Тип файлу:        XLSM (Microsoft Excel Macro-Enabled)
Контейнер:        OpenXML (ZIP + XML + OLE2)
vbaProject.bin:   ПРИСУТНІЙ (OLE2 Composite Document)
Magic bytes:      D0 CF 11 E0 (OLE2)
Auto_Open:        ТАК — автозапуск при відкритті
Прихований аркуш: CdnApi (veryHidden)
Мережеві IOC:     НЕ ЗНАЙДЕНО (навчальний файл)
Shell/Exec:       НЕ ЗНАЙДЕНО (навчальний файл)

Рівень ризику:    СЕРЕДНІЙ

Висновок:
Файл є macro-enabled Excel документом з AutoExec тригером.
Містить прихований аркуш CdnApi. У реально шкідливому файлі
Auto_Open запускав би PowerShell команди для завантаження
корисного навантаження з зовнішнього C2 сервера.
```

---

## Довідник команд

| Команда | Призначення |
|---|---|
| `file <file>` | Визначити тип файлу |
| `unzip -l <file>` | Переглянути структуру ZIP/XLSM |
| `unzip -p <file> <entry> > output` | Витягнути файл з архіву |
| `oleid <file>` | Перевірити тип та індикатори |
| `olevba <file>` | Витягнути VBA код |
| `strings <file>` | Знайти читабельні рядки в бінарному файлі |
| `strings <file> \| grep -iE "pattern"` | Пошук конкретних рядків |
| `xxd <file> \| head` | Hex dump — перевірка magic bytes |

## Таблиця AutoExec тригерів VBA

| Тригер | Коли запускається |
|---|---|
| `Auto_Open` | При відкритті файлу (Excel) |
| `Workbook_Open` | При відкритті книги (Excel) |
| `AutoOpen` | При відкритті документу (Word) |
| `Document_Open` | При відкритті документу (Word) |

---

## Чеклист для самоперевірки

```
[ ] file → визначено XLSM macro-enabled
[ ] unzip -l → знайдено vbaProject.bin
[ ] oleid → запущено, Macro-Enabled підтверджено
[ ] vbaProject.bin → витягнуто до ~/vbaProject.bin
[ ] file ~/vbaProject.bin → Composite Document File V2
[ ] xxd → magic bytes D0 CF 11 E0 знайдено
[ ] strings → знайдено Sub Auto_Open() та MsgBox
[ ] workbook.xml → знайдено прихований аркуш CdnApi
[ ] Результати збережено в ~/analysis_results/
[ ] Висновок написано з рівнем ризику
```

---

*ITS/КСЗІ — Macro Document Analysis Lab | Сценарій 06 (розширення) | ТІЛЬКИ ДЛЯ НАВЧАННЯ | SET University*
