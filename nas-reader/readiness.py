"""Bounded metadata readiness, not an image-integrity scan or network monitor."""
import os
from contextlib import closing
from pathlib import Path
import sqlite3
import time


def inspect_library(source):
    root = Path(source)
    result = dict(storage="unavailable", index="not_checked", catalog="not_checked")
    try:
        for path in (root, root / "books"):
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            os.close(fd)
        result["storage"] = "ready"
        path = root / "index.sqlite3"
        if not path.is_file() or path.is_symlink():
            result["index"] = "unavailable"
            return result
        with closing(sqlite3.connect(path.absolute().as_uri() + "?mode=ro", uri=True, timeout=.25)) as db:
            deadline = time.monotonic() + .25
            db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
            db.execute("PRAGMA query_only=ON")
            db.execute("BEGIN")
            active = db.execute("SELECT value FROM state WHERE key='active'").fetchone()
            result["index"] = "ready"
            if active is None:
                result["catalog"] = "not_published"
            else:
                # Do not load titles, parse a full catalog, count files or read images.
                row = db.execute("SELECT length(body) FROM catalogs WHERE revision=?", (active[0],)).fetchone()
                result["catalog"] = "ready" if row and type(row[0]) is int and 0 < row[0] <= 16*1024*1024 else "unavailable"
    except (OSError, sqlite3.Error, ValueError):
        if result["storage"] == "ready":
            result["index"] = "unavailable"
    return result


def ready(checks):
    return all(checks.get(key) == "ready" for key in ("storage", "index", "catalog"))
