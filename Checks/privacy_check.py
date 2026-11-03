#!/usr/bin/env python3
"""Check the Git index before publication; never print matched secret values."""
from pathlib import Path
import re
import struct
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
patterns = {
    'absolute user path': r'/(?:Users|home)/[A-Za-z0-9_.-]+/',
    'temporary macOS path': r'/var/folders[/]',
    'email address': r'[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    'credential literal': r'(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)',
    'literal UUID (review real account or bot IDs)': r'\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b',
    'embedded image payload': r'data:image/[^,\s]+;base64,[A-Za-z0-9+/]{100}',
    'embedded bearer secret': r'Bearer [A-Za-z0-9_-]{24,}',
}
approved_pngs = {'Assets/Creator.png', 'GrokNotch.icon/Assets/grok-bot-original-polished.png'}
problems = []
for name in filter(None, paths):
    path = root / name
    if path.is_symlink():
        problems.append((name, 'symlink')); continue
    if any(p in {'.build', 'shots', 'screenshots', 'captures', 'data', 'avatars', 'logs', 'work', 'outputs'} for p in path.relative_to(root).parts):
        problems.append((name, 'local artifact directory'))
    if path.name.startswith('.env') or path.name in {'connection.json', 'bridge.pid', '.mcp.json', 'validation-report.json'} or path.suffix in {'.zip', '.log', '.db', '.sqlite', '.pem', '.key', '.p12'}:
        problems.append((name, 'runtime or sensitive file'))
    data = path.read_bytes()
    if name in approved_pngs:
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            problems.append((name, 'invalid PNG')); continue
        pos = 8
        while pos < len(data):
            length = struct.unpack('>I', data[pos:pos+4])[0]
            kind = data[pos+4:pos+8]
            if kind not in {b'IHDR', b'PLTE', b'IDAT', b'tRNS', b'IEND'}:
                problems.append((name, 'unexpected PNG metadata'))
            pos += length + 12
        continue
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        problems.append((name, 'unapproved binary')); continue
    for label, pattern in patterns.items():
        if re.search(pattern, text):
            problems.append((name, label))
if problems:
    for name, label in problems:
        print(f'FAIL: {name}: {label}')
    sys.exit(1)
print(f'PASS: {len(list(filter(None, paths)))} tracked files; no flagged personal data or credentials. Review still required for new content.')
