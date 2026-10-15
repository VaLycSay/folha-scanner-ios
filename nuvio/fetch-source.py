"""Acquire fixed public snapshots without traversing an incomplete Git submodule."""
import hashlib
import io
import json
import pathlib
import stat
import sys
import time
import urllib.request
import zipfile

destination = pathlib.Path(sys.argv[1]).resolve()
with_ios = '--ios' in sys.argv[2:]
records = []

def snapshot(repository, revision, target, expected_hash=None):
    if target.exists() and any(target.iterdir()):
        raise RuntimeError('Refusing to overwrite an existing source tree')
    url = f'https://codeload.github.com/{repository}/zip/{revision}'
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                data = response.read()
            break
        except Exception:
            if attempt == 2: raise
            time.sleep(2 ** attempt)
    digest = hashlib.sha256(data).hexdigest()
    if expected_hash and digest != expected_hash:
        raise RuntimeError(f'Source checksum mismatch for {repository}')
    prefix = repository.rsplit('/', 1)[1] + '-' + revision + '/'
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for member in archive.infolist():
            if not member.filename.startswith(prefix):
                raise RuntimeError('Unexpected archive root')
            relative = member.filename[len(prefix):]
            if not relative: continue
            mode = member.external_attr >> 16
            parts = pathlib.PurePosixPath(relative).parts
            if '..' in parts or relative.startswith('/') or '\\' in relative or stat.S_ISLNK(mode):
                raise RuntimeError('Unsafe archive member')
            output = target.joinpath(*parts)
            if member.is_dir():
                output.mkdir(parents=True, exist_ok=True)
                continue
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open('xb') as file:
                file.write(archive.read(member))
            output.chmod(0o755 if mode & 0o111 else 0o644)
    records.append({'repository': repository, 'commit': revision, 'archive_sha256': digest})

snapshot('NuvioMedia/NuvioMobile', '6d435785c0e082ae3d4fbb8152e1ff5e45c2e575', destination,
         'f09d21318471b0658430f8d35c53efd66474fdecaed8dce0914c7ed31be7f08e')
if with_ios:
    snapshot('NuvioMedia/MPVKit', 'bfeb6fcfa2bd5081a9666ae5bb42b50e6c1537e8', destination / 'MPVKit')
print(json.dumps({'snapshots': records, 'source_only': True}))
