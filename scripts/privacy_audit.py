#!/usr/bin/env python3
"""Offline publication guard. Reports rule + filename, never matched secret values."""
import argparse
import io
import pathlib
import re
import struct
import sys
import zipfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
# Public OAuth client IDs, followed by deliberately synthetic test fixtures.
ALLOWED_UUIDS = {
    'a473d7bb-17ac-43a7-abc0-a1343d7c2805', '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
    '11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222',
    '33333333-3333-4333-8333-333333333333', '44444444-4444-4444-8444-444444444444',
    '55555555-5555-4555-8555-555555555555', '66666666-6666-4666-8666-666666666666',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    'cccccccc-cccc-4ccc-8ccc-cccccccccccc', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
}
RULES = {
    'local-home-path': rb'/(?:Users|home)/[a-zA-Z0-9._-]+/',
    'macos-temp-path': rb'/var/folders/[a-zA-Z0-9_/.-]+',
    'private-key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'service-token': rb'(?:sk-ant-(?:api|oat|ort)[a-zA-Z0-9_-]{20,}|gh[pousr]_[a-zA-Z0-9]{30,}|github_pat_[a-zA-Z0-9_]{30,}|AKIA[A-Z0-9]{16})',
    'jwt': rb'eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}',
    'email': rb'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}',
}
UUID = re.compile(rb'(?<![0-9a-f])[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}(?![0-9a-f])', re.I)
FORBIDDEN = {'.DS_Store', '.env', 'profiles.json', 'usage-cache.json', 'usage-status.json',
             'usage-polling.json', 'trigger-settings.json', 'auth-snapshots', 'migration-backups',
             'chat-backups', 'trigger-runtime', 'Cookies', 'Local Storage', 'IndexedDB'}
IGNORED = {'.git', '.build', '.swiftpm', 'dist', '__pycache__'}
LIMIT = 256 * 1024 * 1024
failures = []
checked = 0

def fail(name, rule):
    failures.append((name, rule))

def check_exif(data):
    """Allow numeric dimensions/orientation and the color-space tag added by iconutil."""
    try:
        order = '>' if data[:2] == b'MM' else '<' if data[:2] == b'II' else None
        if order is None or struct.unpack_from(order + 'H', data, 2)[0] != 42:
            return False
        offsets = [struct.unpack_from(order + 'I', data, 4)[0]]
        seen = set()
        while offsets:
            offset = offsets.pop()
            if offset in seen or len(seen) > 4:
                return False
            seen.add(offset)
            count = struct.unpack_from(order + 'H', data, offset)[0]
            if count > 8:
                return False
            for i in range(count):
                tag, kind, size, value = struct.unpack_from(order + 'HHII', data, offset + 2 + 12 * i)
                if tag == 0x8769 and kind == 4 and size == 1:
                    offsets.append(value)
                elif tag in {0xA001, 0xA002, 0xA003, 0x0112} and kind in {3, 4} and size == 1:
                    pass
                else:
                    return False
            if struct.unpack_from(order + 'I', data, offset + 2 + 12 * count)[0] != 0:
                return False
        return True
    except (struct.error, IndexError):
        return False

def scan(name, data, depth=0):
    global checked
    checked += 1
    parts = pathlib.PurePosixPath(name).parts
    if any(p in FORBIDDEN or p.startswith('._') for p in parts) or name.endswith(('.jsonl', '.p12', '.p8', '.key')):
        fail(name, 'private-or-runtime-file')
    for rule, pattern in RULES.items():
        if re.search(pattern, data):
            fail(name, rule)
    for value in UUID.findall(data):
        if value.decode().lower() not in ALLOWED_UUIDS:
            fail(name, 'unreviewed-uuid')
            break
    if data.startswith(b'PK\x03\x04'):
        if depth > 3:
            fail(name, 'archive-depth'); return
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                if sum(i.file_size for i in archive.infolist()) > LIMIT:
                    fail(name, 'archive-too-large'); return
                for entry in archive.infolist():
                    if not entry.is_dir():
                        if pathlib.PurePosixPath(entry.filename).is_absolute() or '..' in pathlib.PurePosixPath(entry.filename).parts:
                            fail(name, 'unsafe-archive-path')
                        scan(name + '!' + entry.filename, archive.read(entry), depth + 1)
        except (zipfile.BadZipFile, RuntimeError):
            fail(name, 'unreadable-archive')
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        i = 8
        while i + 12 <= len(data):
            size = struct.unpack_from('>I', data, i)[0]
            kind, payload = data[i + 4:i + 8], data[i + 8:i + 8 + size]
            if kind in {b'tEXt', b'zTXt', b'iTXt'}:
                fail(name, 'unreviewed-png-text-metadata')
            if kind == b'eXIf' and not check_exif(payload):
                fail(name, 'unreviewed-image-exif')
            if kind == b'iCCP':
                try:
                    scan(name + '!color-profile', zlib.decompress(payload.split(b'\0', 1)[1][1:]), depth + 1)
                except (zlib.error, IndexError):
                    fail(name, 'unreadable-color-profile')
            i += size + 12
    if data.startswith(b'icns'):
        i = 8
        while i + 8 <= len(data):
            size = struct.unpack_from('>I', data, i + 4)[0]
            if size < 8: break
            payload = data[i + 8:i + size]
            if payload.startswith(b'\x89PNG'):
                scan(name + '!icon-' + str(i), payload, depth + 1)
            i += size

def paths(root, publication=False):
    if root.is_file():
        yield root
        return
    # Exclusions apply only to developer scratch folders. Explicit artifact paths
    # are inspected in full, including any mistakenly packaged runtime files.
    for path in root.rglob('*'):
        relative = path.relative_to(root)
        if not publication and any(p in IGNORED for p in relative.parts):
            continue
        if path.is_symlink():
            fail(str(relative), 'symlink'); continue
        if path.is_file(): yield path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=pathlib.Path)
    parser.add_argument('--artifacts', action='store_true', help='scan explicitly supplied paths without scratch exclusions')
    args = parser.parse_args()
    for root in args.paths or [ROOT]:
        if not root.exists():
            fail(root.name, 'missing-path'); continue
        for path in paths(root, args.artifacts):
            label = str(path.relative_to(root)) if root.is_dir() else root.name
            if path.stat().st_size > LIMIT:
                fail(label, 'file-too-large'); continue
            scan(label, path.read_bytes())
    for name, rule in sorted(set(failures)):
        print(f'FAIL {rule}: {name}')
    print(f'Privacy audit: {checked} files/embedded items; {len(set(failures))} findings.')
    return 1 if failures else 0

if __name__ == '__main__':
    sys.exit(main())
