#!/bin/sh
# Sediakan repo ujian yang mengandungi isu yang diketahui,
# supaya kita boleh buktikan Gate betul-betul mengesan (bukan sekadar "lulus").
# Nota: gitleaks mengabaikan kunci contoh rasmi AWS (AKIAIOSFODNN7EXAMPLE),
# jadi kita jana kunci rawak berentropi tinggi.
set -eu
R=/root/lab-gate/bad
rm -rf /root/lab-gate
mkdir -p "$R"
cd "$R"

AK="AKIA$(tr -dc 'A-Z0-9' < /dev/urandom | head -c 16)"
SK="$(tr -dc 'A-Za-z0-9/+' < /dev/urandom | head -c 40)"

cat > app.py <<EOF
import sqlite3

AWS_ACCESS_KEY = "$AK"
AWS_SECRET = "$SK"


def get_user(name):
    con = sqlite3.connect("db.sqlite")
    query = "SELECT * FROM users WHERE name='" + name + "'"
    return con.execute(query).fetchone()


def run(cmd):
    return eval(cmd)
EOF

printf 'flask==0.5\nrequests==2.0.0\n' > requirements.txt

git init -q
git add -A
git -c user.email=uji@lab -c user.name=uji commit -qm "repo ujian: rahsia + SQLi + pakej lama"
echo "repo ujian siap: $R"
