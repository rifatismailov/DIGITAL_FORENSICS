#!/bin/sh
# SC004 MUDDYWATER — NS1 Alpine container init script
# Copy to /attachments via CyberRanges, runs at container startup

ATTACH="/attachments"
ROOT="/root"
SERVE="$ROOT/serve"
RECV="$ROOT/received"

echo "=== SC004 NS1 INIT START ==="

# Install python3 + pip + dnslib
apk add --no-cache python3 py3-pip > /dev/null 2>&1
pip3 install --quiet dnslib 2>/dev/null

# Create directories
mkdir -p "$SERVE" "$RECV"

# Deploy files from attachments
cp "$ATTACH/c2_http_server.py" "$ROOT/c2_http_server.py"
cp "$ATTACH/c2_server.py"      "$ROOT/c2_server.py"
cp "$ATTACH/implant_drop.rar"  "$SERVE/implant_drop.rar"
cp "$ATTACH/implant.rar"       "$SERVE/implant.rar"

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
python3 /root/c2_server.py --ip $MY_IP --port 53 --out /root/received/
EOF

chmod +x "$ROOT/go_http.sh" "$ROOT/go_dns.sh"

# Touch log files so tail -F works immediately
touch "$ROOT/c2.log" "$RECV/c2_server.log"

# Start HTTP C2 (port 80)
nohup python3 "$ROOT/c2_http_server.py" --port 80 --dir "$SERVE/" \
    > "$ROOT/c2.log" 2>&1 &

# Start DNS C2 (port 53)
nohup python3 "$ROOT/c2_server.py" --ip "$MY_IP" --port 53 --out "$RECV/" \
    >> "$RECV/c2_server.log" 2>&1 &

echo "HTTP C2 : port 80  → $SERVE"
echo "DNS  C2 : port 53  → $MY_IP"
echo "Logs    : $ROOT/c2.log | $RECV/c2_server.log"
echo "=== SC004 NS1 READY ==="

# Keep session alive and stream both logs
tail -F "$ROOT/c2.log" "$RECV/c2_server.log"
