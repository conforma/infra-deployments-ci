#!/usr/bin/env python3
"""Select exactly one release; reject ambiguous pushes and unsafe manual paths."""
import os
from pathlib import Path
import re
import subprocess

release = os.environ.get('RELEASE_DIR', '').removeprefix('releases/')
if release:
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]*', release):
        raise SystemExit('Invalid release directory')
    paths = [f'releases/{release}/images.json']
else:
    changed = subprocess.check_output(['git', 'diff', '--name-only', '--diff-filter=AM',
                                      os.environ['BEFORE_SHA'], os.environ['AFTER_SHA'], '--', 'releases/'], text=True)
    paths = [p for p in changed.splitlines() if re.fullmatch(r'releases/[^/]+/images.json', p)]
if len(paths) != 1 or not Path(paths[0]).is_file():
    raise SystemExit('Expected exactly one release images.json; use manual dispatch to select a release')
print(paths[0])
