#!/usr/bin/env python3
"""two_jup/comb/joinlog.py -- readers for the QPSK_FAILHDR and QPSK_TXLOG
record streams. Layouts are the single-source-of-truth in
host_app_k5/qpsk_join.h (COMB campaign, Task 1); this module is a direct
transcription -- keep it in sync if that header changes.

Both files share a 32 B qpsk_log_hdr ("<8sIIQII": magic, rec_bytes,
n_records, t_dump_ns, total, flags) followed by n_records fixed records.
"""
import os
import struct

import numpy as np

LOG_HDR = struct.Struct("<8sIIQII")
LOG_HDR_SIZE = LOG_HDR.size
assert LOG_HDR_SIZE == 32, LOG_HDR_SIZE

FAILHDR_MAGIC = b"QFAILH01"
TXLOG_MAGIC = b"QTXLOG02"

FAILHDR_DTYPE = np.dtype([
    ("t_mono_ns", "<u8"), ("host_seq", "<u4"), ("first_zero_off", "<u4"),
    ("fail_class", "u1"), ("pad", "u1"), ("magic_off", "<u2"),
    ("hdr", "u1", (12,)),
])
assert FAILHDR_DTYPE.itemsize == 32, FAILHDR_DTYPE.itemsize

TXLOG_DTYPE = np.dtype([
    ("t_submit_ns", "<u8"), ("t_complete_ns", "<u8"), ("seq", "<u4"),
    ("gap_ns", "<u4"), ("slot", "<u4"), ("inflight", "<u2"), ("spins", "<u2"),
])
assert TXLOG_DTYPE.itemsize == 32, TXLOG_DTYPE.itemsize

QPSK_FZO_NONE = 0xFFFFFFFF
QPSK_MAGOFF_NONE = 0xFFFF
QPSK_GAP_NONE = 0xFFFFFFFF
QPSK_LOGF_WRAPPED = 0x1


def _read_hdr_records(path, expect_magic, dtype):
    """Reads a qpsk_log_hdr-prefixed record stream and CHECKS dump
    completeness: file size must equal 32 (header) + rec_bytes * n_records,
    and the magic must match. A short/truncated dump (killed daemon,
    interrupted scp, wrong file) is a silent-wrong-answer risk for any
    census or join built on it, so this raises rather than truncating
    quietly. `wrapped` (flags bit0) is a SEPARATE, non-fatal condition: the
    ring lost its oldest events but the dump itself is complete."""
    size_on_disk = os.path.getsize(path)
    with open(path, "rb") as f:
        raw = f.read(LOG_HDR_SIZE)
        if len(raw) < LOG_HDR_SIZE:
            raise ValueError(f"{path}: too short for a qpsk_log_hdr")
        magic, rec_bytes, n_records, t_dump_ns, total, flags = LOG_HDR.unpack(raw)
        if magic != expect_magic:
            raise ValueError(f"{path}: bad magic {magic!r}, expected {expect_magic!r}")
        if rec_bytes != dtype.itemsize:
            raise ValueError(f"{path}: rec_bytes={rec_bytes} != expected {dtype.itemsize}")
        expect_size = LOG_HDR_SIZE + rec_bytes * n_records
        if size_on_disk != expect_size:
            raise ValueError(
                f"{path}: INCOMPLETE DUMP -- file is {size_on_disk} B, header "
                f"declares {n_records} x {rec_bytes} B + {LOG_HDR_SIZE} B header "
                f"= {expect_size} B (truncated write, wrong file, or a stale "
                f"partial scp)")
        body = np.fromfile(f, dtype=dtype, count=n_records)
    hdr = dict(magic=magic, rec_bytes=rec_bytes, n_records=n_records,
               t_dump_ns=t_dump_ns, total=total, flags=flags,
               wrapped=bool(flags & QPSK_LOGF_WRAPPED),
               size_on_disk=size_on_disk, size_ok=True)
    return hdr, body


def read_failhdr(path):
    """Returns (hdr_dict, structured_array[FAILHDR_DTYPE])."""
    return _read_hdr_records(path, FAILHDR_MAGIC, FAILHDR_DTYPE)


def read_txlog(path):
    """Returns (hdr_dict, structured_array[TXLOG_DTYPE])."""
    return _read_hdr_records(path, TXLOG_MAGIC, TXLOG_DTYPE)


def read_delivered_seqs(path):
    """Reads a --delivered file: the qpsk_join.h `delivered`/`n_delivered`
    array (the tun/qpsk_perf-consumer sequence set), as a raw flat array of
    little-endian uint32 seqs, NO header (unlike QFAILH01/QTXLOG02 -- there
    is no daemon-side producer or ABI for this file yet; qpsk_join.h:239-241
    only documents the in-memory C signature, not an on-disk layout). This
    reader's format is Task 2's own choice, made explicit here so a future
    producer (tun / qpsk_perf) can match it: `struct.pack("<I", seq)` per
    record, back-to-back, file size a multiple of 4. Returns a python set of
    ints for O(1) membership tests.
    """
    if os.path.getsize(path) % 4 != 0:
        raise ValueError(f"{path}: size not a multiple of 4 (not a raw <u4 seq array)")
    raw = np.fromfile(path, dtype="<u4")
    return set(raw.tolist())

