"""Reject accidental local/private files in the distributable source snapshot."""
import re
import sys
import zipfile
from pathlib import Path

archive = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / 'dist/BlueWave-1.0.4-source.zip'
issues = []
with zipfile.ZipFile(archive) as source:
    for name in source.namelist():
        parts = Path(name).parts
        if any(part in {'handoff', 'research', '.git', 'Transcripts', 'Covers'} for part in parts) or Path(name).name == 'library.json':
            issues.append(name + ': private/generated file')
        if name.endswith(('.py', '.swift', '.md', '.txt', '.h', '.mak', '.yml', '.json', '.sh')):
            text = source.read(name).decode('utf-8', errors='replace')
            if re.search(re.escape('/' + 'Users/') + r'[^/\s<>]+/', text):
                issues.append(name + ': absolute home path')
            if re.search(re.escape('/' + 'Volumes/') + r'(?!WALKMAN/|Untitled/|absent/)[^\s\'\"]+', text):
                issues.append(name + ': personal volume path')
if issues:
    raise SystemExit('\n'.join(issues))
print('PASS: public source snapshot excludes personal paths, private library and development records')
