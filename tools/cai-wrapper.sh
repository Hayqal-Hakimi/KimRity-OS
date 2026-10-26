#!/bin/sh
# Pembungkus cai: pakej BlackArch tidak set PYTHONPATH, jadi modul 'cai' tak dijumpai.
# Fail ini di /usr/local/bin (mengatasi /usr/bin/cai) — tidak mengubah pakej.
source /usr/share/cai/venv/bin/activate
export PYTHONPATH="/usr/share/cai/src${PYTHONPATH:+:$PYTHONPATH}"
exec python /usr/share/cai/src/cai/cli.py "$@"
