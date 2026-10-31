#!/bin/sh
# Prepare a test repo containing known issues so we can prove the Gate
# really detects things (not just "passes").
# Note: gitleaks ignores the official AWS example key (AKIAIOSFODNN7EXAMPLE),
# so we generate a high-entropy random key.
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
git -c user.email=test@lab -c user.name=test commit -qm "test repo: secret + SQLi + old packages"
echo "test repo ready: $R"
