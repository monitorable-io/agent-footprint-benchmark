#!/usr/bin/env python3
"""Who is charged for the filesystem's metadata writeback. Stdlib only.

ext4 keeps its metadata (inode tables, bitmaps, directories, extent blocks) in the page cache of the
block device's own inode, and the kernel's cgroup writeback charges all writeback of one inode to one
cgroup: its current owner. For that inode the owner is whichever cgroup the kernel's foreign-inode
detection last picked, and it has nothing to do with who caused the writes. On the 2026 bed the
stream (about 2 to 2.7 MB per hour of 4 KB writes on an idle box) was charged to a mount unit with no
process, to rsyslog, to the root cgroup, and in two measured runs to the agent's own cgroup, where
io.stat then showed 16 MB the agent never wrote.

The tracer enables the kernel tracepoint writeback:writeback_single_inode in a tracefs instance of its
own, filtered to the root filesystem's block-device inode, and turns each event into (cgroup inode,
bytes). The ledger keeps the running sum per measured row, so the summary can publish an agent's disk
writes without the part of that stream that happened to be charged to it.
"""
import os
import re
from pathlib import Path

EVENT = "events/writeback/writeback_single_inode"
INSTANCE = "bench"
LINE = re.compile(r"writeback_single_inode: .*?\bino=(\d+) .*?\bwrote=(\d+) cgroup_ino=(\d+)")


def blockdev_ino(st_dev):
    """The inode number of a block device in the kernel: its dev_t, (major << 20) | minor."""
    return (os.major(st_dev) << 20) | os.minor(st_dev)


def parse_line(line):
    """(inode, pages written, cgroup inode) of one writeback_single_inode trace line, else None."""
    m = LINE.search(line)
    return (int(m.group(1)), int(m.group(2)), int(m.group(3))) if m else None


class Tracer:
    """The tracepoint, armed in /sys/kernel/tracing/instances/bench and read through its trace_pipe.

    The instance is left enabled when the sampler stops: its ring buffer keeps the events of the gap
    and the next sampler process reads them, so a sampler restart loses nothing.
    """

    def __init__(self, tracefs="/sys/kernel/tracing", ino=0, page_size=None):
        self.dir = Path(tracefs) / "instances" / INSTANCE
        self.ino = ino
        self.page = page_size or os.sysconf("SC_PAGE_SIZE")
        self.fd = None
        self.partial = b""

    def arm(self):
        os.makedirs(self.dir, exist_ok=True)   # tracefs builds the instance's tree on mkdir
        event = self.dir / EVENT
        (event / "enable").write_text("0\n")
        try:
            (event / "filter").write_text(f"ino == {self.ino}\n")
        except OSError:
            pass                               # poll() filters again: only the volume read is larger
        (event / "enable").write_text("1\n")
        self.fd = os.open(self.dir / "trace_pipe", os.O_RDONLY | os.O_NONBLOCK)

    def poll(self):
        """{cgroup inode: bytes} written back for the watched inode since the previous poll."""
        if self.fd is None:
            return {}
        chunks = []
        while True:
            try:
                data = os.read(self.fd, 65536)
            except BlockingIOError:
                break
            if not data:
                break
            chunks.append(data)
        lines = (self.partial + b"".join(chunks)).split(b"\n")
        self.partial = lines.pop()             # empty, or a line the kernel has not finished
        out = {}
        for raw in lines:
            parsed = parse_line(raw.decode("ascii", "replace"))
            if parsed and parsed[0] == self.ino and parsed[1] > 0:
                out[parsed[2]] = out.get(parsed[2], 0) + parsed[1] * self.page
        return out

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class Ledger:
    """Running sums: per measured row (its cgroup and every cgroup below it) and for the whole box."""

    def __init__(self):
        self.rows = {}
        self.owner = {}    # cgroup inode -> row, remembered after a transient child cgroup is gone
        self.total = 0

    def add(self, charged, row_inodes):
        """charged: Tracer.poll(); row_inodes: {row: inodes of its cgroup and of every cgroup below}."""
        for row, inodes in row_inodes.items():
            for ino in inodes:
                self.owner[ino] = row
        for ino, nbytes in charged.items():
            self.total += nbytes
            row = self.owner.get(ino)
            if row is not None:
                self.rows[row] = self.rows.get(row, 0) + nbytes

    def row(self, row):
        return self.rows.get(row, 0)


def cgroup_inodes(d):
    """Inodes of cgroup directory `d` and of every cgroup directory below it."""
    found = set()
    for dirpath, _dirs, _files in os.walk(d):
        try:
            found.add(os.stat(dirpath).st_ino)
        except OSError:
            continue
    return found


def cgroup_names(root):
    """{inode: path relative to root ('/' for the root)} of every cgroup; used to name an owner."""
    names = {}
    for dirpath, _dirs, _files in os.walk(root):
        try:
            names[os.stat(dirpath).st_ino] = "/" + os.path.relpath(dirpath, root).replace(os.sep, "/").lstrip(".").lstrip("/")
        except OSError:
            continue
    return names
