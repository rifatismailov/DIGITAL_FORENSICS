# Лабораторна робота — Сценарій 10: Цифрові підписи GPG

Назва лабораторної: Digital Signatures — GPG Key Management
Модуль: Криптографія / Цифрові підписи
Сценарій: 10 — Creating and Verifying Digital Signatures
Формат: Self-Paced
Версія документу: 1.0

---

## Мета

Навчитися створювати пари GPG ключів, підписувати файли цифровим підписом та верифікувати підписи. Зрозуміти різницю між приватним та публічним ключем, принцип роботи асиметричної криптографії.

---

## Середовище та інструментарій

Замість Kleopatra (Windows GUI) використовуємо **GPG** — той самий стандарт OpenPGP через термінал Ubuntu. Kleopatra є графічною оболонкою над GPG.

| Kleopatra (Windows) | GPG термінал (Ubuntu) | Призначення |
|---|---|---|
| Кнопка «New Key Pair» | `gpg --gen-key` | Створення ключів |
| Кнопка «Sign» | `gpg --sign` | Підпис файлу |
| Кнопка «Verify» | `gpg --verify` | Верифікація підпису |
| Кнопка «Export» | `gpg --export` | Експорт публічного ключа |
| Keyring | `~/.gnupg/` | Сховище ключів |

Перевірити наявність GPG:

```bash
gpg --version
```

---

## Фаза 1 — Створення пари ключів

### Крок 1.1 — Згенерувати ключову пару

```bash
gpg --gen-key
```

GPG запитає:
- **Real name:** введи своє ім'я (наприклад `Student25`)
- **Email address:** введи email (наприклад `student25@techfrontier.ua`)
- **Passphrase:** придумай пароль для захисту приватного ключа

### Крок 1.2 — Переглянути список ключів

```bash
# Публічні ключі
gpg --list-keys

# Приватні ключі
gpg --list-secret-keys
```

**Очікуваний результат:**
```
pub   ed25519 2024-03-27 [SC]
      A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2
uid           [ultimate] Student25 <student25@techfrontier.ua>
sub   cv25519 2024-03-27 [E]
```

Запиши свій **fingerprint** (40 символів):

| Поле | Значення |
|---|---|
| Fingerprint | |
| Email | |
| Тип ключа | |
| Дата створення | |

---

## Фаза 2 — Підписання файлу

### Крок 2.1 — Створити тестовий файл

```bash
cat > ~/document.txt << 'DOCEOF'
TechFrontier UA — Офіційний документ
Дата: 27.03.2024
Зміст: Договір з клієнтом №2024-042
Сума: 150 000 грн
Підписант: Дарія Кравець, IT-спеціаліст
DOCEOF

cat ~/document.txt
```

### Крок 2.2 — Підписати файл (detached signature)

```bash
gpg --detach-sign --armor ~/document.txt
```

Це створить файл підпису `~/document.txt.asc`.

```bash
ls -lh ~/document.txt ~/document.txt.asc
```

### Крок 2.3 — Переглянути файл підпису

```bash
cat ~/document.txt.asc
```

**Очікуваний результат:**
```
-----BEGIN PGP SIGNATURE-----

iQEzBAABCAAdFiEE...
...
-----END PGP SIGNATURE-----
```

**Що означає:**
* `-----BEGIN PGP SIGNATURE-----` — стандартний заголовок ASCII armor
* Тіло підпису — base64-encoded бінарні дані підпису
* Підпис містить хеш документу + зашифровано приватним ключем

---

## Фаза 3 — Верифікація підпису

### Крок 3.1 — Верифікувати підпис (файл не змінено)

```bash
gpg --verify ~/document.txt.asc ~/document.txt
```

**Очікуваний результат:**
```
gpg: Signature made Wed 27 Mar 2024
gpg:                using ED25519 key A1B2C3D4...
gpg: Good signature from "Student25 <student25@techfrontier.ua>"
```

** `Good signature`** — підпис валідний, файл не змінено.

### Крок 3.2 — Симулювати підробку документу

```bash
# Змінити документ після підписання
echo "ПІДРОБЛЕНО: сума змінена на 999 000 грн" >> ~/document.txt

# Верифікувати знову
gpg --verify ~/document.txt.asc ~/document.txt
```

**Очікуваний результат:**
```
gpg: Signature made Wed 27 Mar 2024
gpg:                using ED25519 key A1B2C3D4...
gpg: BAD signature from "Student25 <student25@techfrontier.ua>"
```

** `BAD signature`** — файл був змінений після підписання!

Запиши:

| Сценарій | Результат верифікації |
|---|---|
| Оригінальний файл | Good / Bad |
| Змінений файл | Good / Bad |

---

## Фаза 4 — Обмін ключами та перехресна верифікація

### Крок 4.1 — Експортувати свій публічний ключ

```bash
gpg --export --armor student25@techfrontier.ua > ~/public_key.asc
cat ~/public_key.asc
```

### Крок 4.2 — Імпортувати ключ іншого студента

```bash
# Отримати публічний ключ від іншого студента
# Наприклад student1 зберіг свій ключ в /opt/lab/scenario/
gpg --import /opt/lab/scenario/student1_public.asc
```

### Крок 4.3 — Верифікувати файл підписаний іншим студентом

```bash
gpg --verify /opt/lab/scenario/student1_document.txt.asc \
             /opt/lab/scenario/student1_document.txt
```

---

## Фаза 5 — Шифрування та розшифрування

### Крок 5.1 — Зашифрувати файл для себе

```bash
# Відновити оригінальний файл
cat > ~/secret.txt << 'SECEOF'
Конфіденційно: паролі до серверів TechFrontier UA
ERP: admin/Erp@2024
VPN: vpnuser/Vpn@Secure2024
SECEOF

# Зашифрувати своїм публічним ключем
gpg --encrypt --armor --recipient student25@techfrontier.ua ~/secret.txt
```

Це створить `~/secret.txt.asc`.

### Крок 5.2 — Розшифрувати файл

```bash
gpg --decrypt ~/secret.txt.asc
```

GPG запитає passphrase приватного ключа.

---

## Фаза 6 — Підпис + шифрування разом

```bash
cat > ~/official_doc.txt << 'DOCEOF'
Офіційний підписаний та зашифрований документ
Від: Student25
Дата: 27.03.2024
DOCEOF

# Підписати І зашифрувати одночасно
gpg --sign --encrypt --armor \
    --recipient student25@techfrontier.ua \
    ~/official_doc.txt

ls ~/official_doc.txt.asc
```

---

## Фаза 7 — Збереження результатів

```bash
mkdir -p ~/gpg_results

gpg --list-keys > ~/gpg_results/01_keys.txt
cat ~/document.txt.asc > ~/gpg_results/02_signature.txt
gpg --verify ~/document.txt.asc ~/document.txt \
    > ~/gpg_results/03_verify_good.txt 2>&1

# Верифікація зміненого файлу
gpg --verify ~/document.txt.asc ~/document.txt \
    > ~/gpg_results/04_verify_bad.txt 2>&1

echo "Результати збережено:"
ls -lh ~/gpg_results/
```

### Написати висновок

```bash
nano ~/gpg_results/conclusion.txt
```

```
ЛАБОРАТОРНА РОБОТА: Цифрові підписи GPG
=========================================
Дата:      [сьогоднішня дата]
Студент:   [твоє ім'я]

1. Створено ключову пару:
   Fingerprint: [твій fingerprint]
   Тип: ED25519

2. Підписано файл: document.txt
   Підпис: document.txt.asc (ASCII armor)

3. Результати верифікації:
   - Оригінальний файл: Good signature 
   - Змінений файл:     BAD signature  

4. Висновок:
   Цифровий підпис гарантує цілісність документу.
   Будь-яка зміна після підписання робить підпис
   недійсним. Це унеможливлює підробку підписаних
   документів без виявлення.
```

---

## Ключові поняття

| Термін | Пояснення |
|---|---|
| **Приватний ключ** | Секретний ключ — тільки у власника. Використовується для підписання |
| **Публічний ключ** | Відкритий ключ — можна поширювати. Використовується для верифікації |
| **Detached signature** | Підпис в окремому файлі (.asc) — оригінальний файл не змінюється |
| **ASCII armor** | Base64-кодування бінарних даних для передачі текстом |
| **Fingerprint** | Унікальний хеш публічного ключа для ідентифікації |
| **Good signature** | Файл не змінювався після підписання |
| **BAD signature** | Файл був змінений або підпис підроблений |

---

## Довідник команд

| Команда | Призначення |
|---|---|
| `gpg --gen-key` | Створити нову ключову пару |
| `gpg --list-keys` | Переглянути публічні ключі |
| `gpg --list-secret-keys` | Переглянути приватні ключі |
| `gpg --detach-sign --armor <file>` | Підписати файл (окремий підпис) |
| `gpg --verify <sig> <file>` | Верифікувати підпис |
| `gpg --export --armor <email>` | Експортувати публічний ключ |
| `gpg --import <file>` | Імпортувати публічний ключ |
| `gpg --encrypt --armor -r <email> <file>` | Зашифрувати файл |
| `gpg --decrypt <file>` | Розшифрувати файл |
| `gpg --delete-key <email>` | Видалити публічний ключ |

---

## Чеклист для самоперевірки

```
[ ] Встановлено GPG та перевірено версію
[ ] Створено ключову пару (приватний + публічний)
[ ] Записано fingerprint свого ключа
[ ] Підписано document.txt (detached signature)
[ ] Верифіковано підпис — Good signature
[ ] Симульовано підробку — BAD signature
[ ] Зашифровано та розшифровано файл
[ ] Результати збережено в ~/gpg_results/
[ ] Написано висновок
```

---

*ITS/КСЗІ — Digital Signatures Lab | Сценарій 10 | ТІЛЬКИ ДЛЯ НАВЧАННЯ | SET University*
