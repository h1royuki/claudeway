#!/usr/bin/env python3
"""Synthetic regression checks for the publication guard; no real secrets."""
import io
import zipfile
import privacy_audit as audit

def finds(payload, rule, name='fixture.txt'):
    audit.failures.clear()
    audit.scan(name, payload)
    assert any(r == rule for _, r in audit.failures), rule

finds(b'/Users/' + b'example/local/file.swift', 'local-home-path')
finds(b'sk-ant-api' + b'x' * 40, 'service-token')
finds(b'person' + b'@' + b'example.invalid', 'email')
finds(b'{"name":"demo"}', 'private-or-runtime-file', 'profiles.json')
finds(b'12345678' + b'-1234-4234-8234-123456789abc', 'unreviewed-uuid')
archive = io.BytesIO()
with zipfile.ZipFile(archive, 'w') as z:
    z.writestr('data/secret.txt', b'/home/' + b'example/project/file')
finds(archive.getvalue(), 'local-home-path', 'nested.zip')
audit.failures.clear()
audit.scan('safe.swift', b'let token = "FAKE-valid"; let path = "~/Library/Application Support/Claude"')
assert not audit.failures
assert audit.check_exif(bytes.fromhex('4d4d002a00000008000187690004000000010000001a000000000002a00200040000000100000400a0030004000000010000040000000000'))
generated_exif = bytes.fromhex('4d4d002a00000008000187690004000000010000001a000000000003a00100030000000100010000a00200040000000100000040a0030004000000010000004000000000')
assert audit.check_exif(generated_exif)
# Replacing the color-space tag with Artist must still fail, even with numeric data.
assert not audit.check_exif(generated_exif.replace(bytes.fromhex('a001'), bytes.fromhex('013b')))
print('PASS publication guard: paths, credentials, emails, runtime files, IDs, archives and bounded image metadata')
