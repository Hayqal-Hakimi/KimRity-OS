#!/usr/bin/env python3
"""qemu-type.py — type text into a guest through the QEMU monitor socket.

The installer test drives a *live* archiso shell, and the only reliable input
channel is the monitor's `sendkey`: OCR can read the screen, but it cannot press
keys. This turns a string into sendkey events.

The monitor path is taken from MON (or --monitor); there is no default, because
a wrong default is how the old script failed with "FileNotFoundError: mon12.sock"
on every run that used a different socket.

Usage:
    MON=/tmp/vm.sock qemu-type.py 'echo hello'
    MON=/tmp/vm.sock qemu-type.py @commands.txt      # read the text from a file
    MON=/tmp/vm.sock qemu-type.py 'echo hi' 0.02     # keystroke delay in seconds

Only characters that fit a US layout are sent; anything else is skipped, which
matches how the live ISO is configured (install.sh default keymap = us).
"""
import os
import socket
import sys
import time

US_PLAIN = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left",
    "]": "bracket_right", "\\": "backslash", ";": "semicolon", "'": "apostrophe",
    "`": "grave_accent", ",": "comma", ".": "dot", "/": "slash",
}
US_SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal", "{": "bracket_left",
    "}": "bracket_right", "|": "backslash", ":": "semicolon", '"': "apostrophe",
    "~": "grave_accent", "<": "comma", ">": "dot", "?": "slash",
}
NAMED = {"\t": "tab", "\x1b": "esc"}


def key_for(ch):
    """Return (key name, needs shift) for one character, or (None, False)."""
    if ch in NAMED:
        return NAMED[ch], False
    if ch in US_PLAIN:
        return US_PLAIN[ch], False
    if ch in US_SHIFTED:
        return US_SHIFTED[ch], True
    if ch.isalpha():
        return ch.lower(), ch.isupper()
    if ch.isdigit():
        return ch, False
    return None, False


def send(sock_path, line):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(sock_path)
        s.sendall(line.encode())
    finally:
        s.close()


def main():
    mon = os.environ.get("MON", "")
    args = sys.argv[1:]
    if args and args[0] in ("-m", "--monitor"):
        mon = args[1] if len(args) > 1 else ""
        args = args[2:]
    if not mon:
        sys.exit("qemu-type.py: set MON=/path/to/monitor.sock (no default on purpose)")
    if not args:
        sys.exit("qemu-type.py: nothing to type (pass text or @file)")
    if not os.path.exists(mon):
        sys.exit(f"qemu-type.py: monitor socket not found: {mon}")

    arg = args[0]
    delay = float(args[1]) if len(args) > 1 else 0.08
    text = open(arg[1:], encoding="utf-8").read() if arg.startswith("@") else arg

    skipped = []
    for ch in text:
        key, shift = key_for(ch)
        if key is None:
            skipped.append(ch)
            continue
        send(mon, f"sendkey shift-{key}\n" if shift else f"sendkey {key}\n")
        time.sleep(delay)
    if skipped:
        sys.stderr.write("qemu-type.py: skipped %d char(s) outside US layout: %r\n"
                         % (len(skipped), "".join(sorted(set(skipped)))))


if __name__ == "__main__":
    main()
