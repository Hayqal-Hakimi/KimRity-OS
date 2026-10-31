#!/bin/sh
# cai wrapper: the BlackArch package does not set PYTHONPATH, so the 'cai' module is not found.
# This file lives in /usr/local/bin (overrides /usr/bin/cai) — the package itself is not modified.
source /usr/share/cai/venv/bin/activate
export PYTHONPATH="/usr/share/cai/src${PYTHONPATH:+:$PYTHONPATH}"
exec python /usr/share/cai/src/cai/cli.py "$@"
