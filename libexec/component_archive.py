#!/usr/bin/env python3
"""Extract bounded component archives without links or paths outside the root."""
import pathlib
import shutil
import stat
import sys
import tarfile
import zipfile

archive, target = sys.argv[1:]
root = pathlib.Path(target)
root.mkdir(parents=True, exist_ok=True)
limit = 256 * 1024 * 1024
total = 0
seen = set()


def destination(name, size):
    global total
    path = pathlib.PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name or any(ord(c) < 32 for c in name):
        raise ValueError("unsafe archive path")
    if path == pathlib.PurePosixPath("."):
        return root
    if str(path) in seen:
        raise ValueError("duplicate archive path")
    seen.add(str(path))
    total += size
    if len(seen) > 10000 or total > limit:
        raise ValueError("archive exceeds extraction limits")
    return root.joinpath(*path.parts)


if zipfile.is_zipfile(archive):
    with zipfile.ZipFile(archive) as src:
        entries = []
        for item in src.infolist():
            mode = item.external_attr >> 16
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("special archive entry")
            entries.append((item, destination(item.filename, item.file_size)))
        for item, path in entries:
            if item.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with src.open(item) as stream, path.open("xb") as out:
                    shutil.copyfileobj(stream, out)
                path.chmod(0o600)
else:
    with tarfile.open(archive, "r:gz") as src:
        entries = []
        for item in src:
            if not item.isdir() and not item.isfile():
                raise ValueError("special archive entry")
            entries.append((item, destination(item.name, item.size)))
        for item, path in entries:
            if item.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with src.extractfile(item) as stream, path.open("xb") as out:
                    shutil.copyfileobj(stream, out)
                path.chmod(0o600)
