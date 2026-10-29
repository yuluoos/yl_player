"""Publish a completed offline trace without exposing or replacing partial data."""
import os
from pathlib import Path
import tempfile


def publish_trace(destination, data):
    """POSIX host filesystems only; unsupported hard links fail closed.

    Stage beside the destination so the exclusive link stays on one filesystem.
    No final path exists until writing, flushing and closing have succeeded.
    This is file publication, not an atomic transaction with stdout or a promise
    of directory-entry durability across a power loss.
    """
    destination = Path(destination)
    with tempfile.TemporaryDirectory(prefix='.yl-dolby-trace-', dir=destination.parent) as directory:
        staged = Path(directory)/'trace'
        fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        # Unlike rename/replace, link atomically refuses an existing destination,
        # including dangling symlinks and a concurrent writer's completed trace.
        os.link(staged, destination)
