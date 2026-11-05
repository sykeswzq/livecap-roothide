#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Convert all unicode escape sequences in source files to actual UTF-8 characters.

Run: python3 fix_unicode_escapes.py

This script:
1. Reads each source file
2. Finds all backslash-u-XXXX patterns (single backslash + u + 4 hex digits)
3. Converts them to the actual UTF-8 character
4. Writes back to the same file
"""
import re
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

files = [
    os.path.join(HERE, "PrefBundle", "LiveCapAppListController.m"),
    os.path.join(HERE, "PrefBundle", "LiveCapPrefs.m"),
]

def convert_escapes(content: str) -> tuple:
    """Convert backslash-u-XXXX sequences to actual Unicode chars. Return (new_content, count)."""
    def repl(m):
        return chr(int(m.group(1), 16))
    matches = re.findall(r'\\u([0-9a-fA-F]{4})', content)
    new = re.sub(r'\\u([0-9a-fA-F]{4})', repl, content)
    return new, len(matches)

ok = True
for f in files:
    if not os.path.exists(f):
        print(f"[SKIP] not found: {f}")
        continue
    with open(f, "r", encoding="utf-8") as fp:
        content = fp.read()
    new, n = convert_escapes(content)
    if n == 0:
        print(f"[OK] {f}: no escapes to convert")
        continue
    with open(f, "w", encoding="utf-8") as fp:
        fp.write(new)
    print(f"[FIX] {f}: converted {n} escapes")

print("Done.")
