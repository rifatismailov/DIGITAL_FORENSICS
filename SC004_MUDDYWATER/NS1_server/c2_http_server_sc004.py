#!/usr/bin/env python3
# =============================================================================
# c2_http_server.py — HTTP сервер для доставки implant.zip
# Запускати на 172.16.50.10 (NS1)
# EXERCISE ONLY — Blue Team Training
# =============================================================================
# Запуск:
#   sudo python3 c2_http_server.py
#   sudo python3 c2_http_server.py --port 80 --dir ./serve/
#
# Підготовка implant.zip:
#   mkdir -p serve
#   cp implant.ps1 config.ps1 block*.ps1 serve/
#   cd serve && zip implant.zip implant.ps1 config.ps1 block*.ps1
# =============================================================================

import http.server
import socketserver
import os
import argparse
from datetime import datetime

SERVE_DIR = "./serve"
PORT      = 80

class LoggingHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        ts  = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        src = self.client_address[0]
        msg = format % args
        line = f"{ts} [HTTP] [{src}] {msg}"
        print(line)
        with open("c2_http.log", "a") as f:
            f.write(line + "\n")

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except ConnectionResetError:
            pass  # client probe — TCP connect then immediate reset, not an error

    def do_GET(self):
        ts  = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        src = self.client_address[0]
        print(f"{ts} [DOWNLOAD] [{src}] GET {self.path}")
        super().do_GET()

def run(port, serve_dir):
    os.makedirs(serve_dir, exist_ok=True)
    os.chdir(serve_dir)

    socketserver.ThreadingTCPServer.allow_reuse_address = True
    with socketserver.ThreadingTCPServer(("", port), LoggingHandler) as httpd:
        print(f"{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} [START] HTTP server on port {port}")
        print(f"Serving: {os.path.abspath('.')}")
        for f in ["implant.rar", "implant_drop.rar"]:
            status = "EXISTS" if os.path.exists(f) else "NOT FOUND!"
            print(f"{f}: {status}")
        httpd.serve_forever()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default=80, type=int)
    parser.add_argument("--dir",  default=SERVE_DIR)
    args = parser.parse_args()
    run(args.port, args.dir)
