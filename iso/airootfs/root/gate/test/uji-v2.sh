#!/bin/sh
# Gate v2 test: web + server, target = the VM itself (127.0.0.1).
# Provides:
#   - an HTTP 8080 server with a exposed .git/config  → nuclei/nikto test
#   - a fake listener on 3306                         → nmap port policy test
set -u
GATE=/opt/kimrity/gate/gate.py
pkill -f "http.server 8080" 2>/dev/null
pkill -f "fake3306" 2>/dev/null
sleep 1

mkdir -p /root/webtest/.git
printf '[core]\n\trepositoryformatversion = 0\n' > /root/webtest/.git/config
printf 'index.html\n' > /root/webtest/index.html

cd /root/webtest
nohup python3 -m http.server 8080 --bind 127.0.0.1 >/dev/null 2>&1 &
nohup python3 -c "
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 3306))
s.listen(5)
while True:
    c, _ = s.accept()
    c.send(b'fake mysql 5.5.0\n')
    c.close()
" >/dev/null 2>&1 &
sleep 2
ss -ltn | grep -E ':8080|:3306'

echo "=================== TEST A: WEB ==================="
python3 "$GATE" http://127.0.0.1:8080 --kind web --authorized --out /root/webtest/out-web 2>&1 | tail -4
sed -n '1,26p' /root/webtest/out-web/report.md

echo "=================== TEST B: SERVER ==================="
python3 "$GATE" 127.0.0.1 --kind server --authorized --out /root/webtest/out-srv 2>&1 | tail -4
sed -n '1,26p' /root/webtest/out-srv/report.md

echo "=================== TEST C: GUARD ==================="
echo "-- C1: web/server without --authorized (must be rejected)"
python3 "$GATE" 127.0.0.1 --kind server --out /tmp/g1 >/tmp/g1.log 2>&1; echo "exit=$?"; tail -1 /tmp/g1.log
echo "-- C2: target outside the scope file (must be rejected)"
echo "allowed.example.com" > /tmp/scope.txt
python3 "$GATE" 127.0.0.1 --kind server --authorized --scope /tmp/scope.txt --out /tmp/g2 >/tmp/g2.log 2>&1; echo "exit=$?"; tail -1 /tmp/g2.log
echo "-- C3: target INSIDE the scope file (must be accepted)"
printf "127.0.0.1\n192.168.1.0/24\n" > /tmp/scope2.txt
python3 "$GATE" 127.0.0.1 --kind server --authorized --scope /tmp/scope2.txt --out /tmp/g3 --quiet >/tmp/g3.log 2>&1; echo "exit=$?"; tail -2 /tmp/g3.log
