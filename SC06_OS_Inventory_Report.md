# Початковий звіт про інвентаризацію ОС та програмного забезпечення

**Назва лабораторної:** Email Forensics — Доставка шкідливого ПЗ через підроблений рахунок
**Модуль:** Аналіз електронної пошти / Аналіз інцидентів
**Сценарій:** Fake Invoice (Emotet-style XLSM Dropper)
**Формат:** Self-Paced
**Версія документу:** 1.0

#### 1. Інвентаризація операційних систем та програмного забезпечення

Цей розділ фіксує операційні системи та основні програмні пакети, встановлені на кожному пристрої середовища.

| Hostname пристрою | Операційна система | Основне програмне забезпечення та сервіси |
|---|---|---|
| analyst-workstation | Linux (Ubuntu 24.04 LTS Desktop) | Docker Engine 26.x, Docker Compose 2.x, Python 3.12, tcpdump, emlAnalyzer 3.0.1, OpenSSH Server, стандартне робоче середовище GNOME |
| forensics_sc06_invoice | Linux (Python 3.12-slim, Docker-контейнер) | Python 3.12, Flask 3.0.3, Scapy 2.6.1. Містить веб-поштовий клієнт `app.py`, фішинговий лист `06_malware_invoice.eml`, генератор артефактів `generate_artifacts.py`, PCAP-файл `traffic.pcap` та журнали безпеки |
| forensics_sc06_c2 | Linux (Python 3.12-slim, Docker-контейнер) | Python 3.12, Flask 3.0.3. Містить mock C2-сервер `c2_server.py`, що імітує поведінку командного сервера зловмисника |

#### 2. IP-адресація та доступ для адміністрування

Цей розділ містить деталі мережевих інтерфейсів, призначені адреси та облікові дані для доступу до кожної системи.

| Пристрій | Інтерфейс | IPv4-адреса | Маска | Ім'я користувача | Пароль |
|---|---|---|---|---|---|
| analyst-workstation | eth0 | 192.168.88.202 | /24 | analyst | analyst |
| analyst-workstation | br-sc06_net | 172.22.0.1 | /24 | — | — |
| forensics_sc06_invoice | eth0 (всередині контейнера) | 172.22.0.16 | /24 | root | — |
| forensics_sc06_invoice | eth1 (c2_net) | 172.23.0.16 | /24 | root | — |
| forensics_sc06_c2 | eth0 (c2_net) | 172.23.0.200 | /24 | root | — |
| student1–student25 | eth0 | (успадковується від хоста) | /24 | student1–student25 | student1–student25 |

#### 3. Конфігурація маршрутизації та впровадження загроз

Цей розділ описує спеціально підготовлений електронний лист, мережеві артефакти та журнали, необхідні для роботи лабораторної відповідно до навчального плану.

* **Впровадження фішингового листа:** Файл `06_malware_invoice.eml` знаходиться на робочій станції аналітика за адресою `~/scenario/emails/06_malware_invoice.eml` та подається через веб-поштовий клієнт на `http://localhost:8086` або `http://192.168.88.202:8086`. Заголовок `Authentication-Results` містить записи `spf=fail`, `dkim=fail` та `dmarc=fail`. Поле `Reply-To` вказує на `finance-dept@proton.me` (безкоштовний сервіс, а не корпоративний). Ланцюг `Received` містить підроблений хоп `from localhost (127.0.0.1)`. HTML-тіло містить кнопку, атрибут `href` якої веде на `cdn-updates-service.com`, тоді як відображуваний текст посилання показує `docs.google.com`. Піксель відстеження розміром 1×1 завантажується з `cdn-updates-service.com/track/pixel.gif`. Студент повинен самостійно відкрити веб-поштовий інтерфейс та проаналізувати необроблені заголовки, HTML-тіло і метадані вкладення для виявлення всіх IOC.

* **Захоплення мережевого трафіку:** PCAP-файл генерується всередині контейнера `forensics_sc06_invoice` за адресою `/root/analysis/traffic.pcap` та копіюється на хост командою `sudo docker cp forensics_sc06_invoice:/root/analysis/traffic.pcap ~/scenario/sc06.pcap`. Файл містить 1241 пакет: легітимний корпоративний фоновий трафік (DNS, ICMP, NTP, HTTP, SMTP, SMB, TLS) з 08:00 до 11:30, після чого о 11:32 починається ланцюг атаки. DNS-запит до `cdn-updates-service.com` резолвиться в `185.156.72.11` о `11:32:30`. Два завантаження корисного навантаження відбуваються з User-Agent Microsoft Office (`get_payload.ps1`) та PowerShell (`svchost_helper.dll`). Вісім маякових POST-запитів до `185.156.72.11:8080` з інтервалом ~120 секунд використовують рядок User-Agent IE11 від небраузерного процесу — відбиток Emotet. Спроба ексфільтрації POST до `/cdn/telemetry/upload` повертає HTTP 403. Студент повинен самостійно використати `tcpdump` для аналізу та зіставлення мережевих IOC.

* **Артефакти журналів безпеки:** Журнали генеруються всередині контейнера `forensics_sc06_invoice`. Журнал антивірусу `/var/log/security/av_alerts.log` містить 124 рядки та документує повний ланцюг атаки: доставку листа, виконання макросу, породження процесів `EXCEL.EXE → cmd.exe → powershell.exe`, мережеві з'єднання, скидання DLL у `%TEMP%`, запис ключа Run у реєстрі та маяки C2. Транскрипт PowerShell `/var/log/security/powershell_transcript.log` фіксує конструкцію `IEX(DownloadString(...))`, виклик `DownloadFile`, створення ключа реєстру `WinSvcHost`, створення м'ютекса `Local\WinSvcHostV2` та рефлексивне завантаження DLL. Журнал вебдоступу `/var/log/web/access.log` містить 67 рядків з легітимними корпоративними запитами та записами атаки. Студент повинен самостійно зайти до контейнера та прочитати кожен журнал для зіставлення знахідок із мережевими даними.

#### 4. Схема мережевої архітектури

```
analyst-workstation (Ubuntu 26)
│
│  http://localhost:8086 
   http://192.168.88.202:8086
│
├── Docker Network: sc06_net (172.22.0.0/24) [bridge]
│   ├── forensics_sc06_invoice — 172.22.0.16 : 8080 → localhost:8086
│   └── (також підключений до c2_net)
│
└── Docker Network: sc06_c2_net (172.23.0.0/24) [internal]
    ├── forensics_sc06_invoice — 172.23.0.16
    └── forensics_sc06_c2     — 172.23.0.200
```


*Forensics |  Fake Invoice (Emotet-style XLSM Dropper)| EDUCATIONAL USE ONLY | Rifat Ismailov*