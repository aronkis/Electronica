#!/usr/bin/env python3
"""gen_frames.py -- synthetic RX byte-stream frames for the SEQ-BIST unit sims.

Reproduces the qpsk_traffic_gen / qpsk_frame.c frame exactly:

  bytes [0..1]   0x51 0x4B          magic
  bytes [2..3]   len, LE            (fill_len, <= 1516)
  bytes [4..7]   seq, LE
  bytes [8..11]  CRC field          0x54474E21 ("TGN!") in TGEN mode, or the
                                    host CRC32 (reflected poly 0xEDB88320,
                                    init/final 0xFFFFFFFF) over bytes
                                    [0 .. 12+len-1] with this field zeroed
  bytes [12..]   xorshift32 PN, seeded (seq ^ 0x9E3779B9) or 0xDEADBEEF if 0,
                 one xorshift round per payload byte, low byte taken
  ... zero padded to 1528 bytes = 191 x 64-bit little-endian words.

Used by jupiter_240k5_byte/rtl_sim/seqbist_unit/tb_rx_seq_checker.v: writes a
word/user stream plus the exact expected value of all 16 rx_seq_checker
counters, computed by an explicit model of the documented semantics.

Run standalone to (re)generate the vectors:
    python3 two_jup/seqbist/gen_frames.py <outdir>
"""
import sys
import os

PKT_BYTES = 1528
HDR_BYTES = 12
WORDS = 191
TGEN_CRC = 0x54474E21
SKIP_N = 5          # skip_every used by the end-to-end positive-control vector
CORR_M = 8          # corrupt_every used by the end-to-end positive-control vector
M32 = 0xFFFFFFFF


def xs(x):
    a = (x ^ (x << 13)) & M32
    b = a ^ (a >> 17)
    return (b ^ (b << 5)) & M32


def pn_bytes(seq, n):
    seed = (seq ^ 0x9E3779B9) & M32
    pn = 0xDEADBEEF if seed == 0 else seed
    out = bytearray()
    for _ in range(n):
        pn = xs(pn)
        out.append(pn & 0xFF)
    return bytes(out)


_CRC_TAB = []
for _i in range(256):
    _c = _i
    for _ in range(8):
        _c = (_c >> 1) ^ (0xEDB88320 if _c & 1 else 0)
    _CRC_TAB.append(_c)


def crc32(buf):
    c = M32
    for b in buf:
        c = _CRC_TAB[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ M32


def build_frame(seq, fill=1516, tgen=True, bad_magic=False, bad_crc=False):
    """Return the 1528-byte frame image."""
    f = bytearray(PKT_BYTES)
    f[0] = 0x51
    f[1] = 0x4B
    f[2] = fill & 0xFF
    f[3] = (fill >> 8) & 0x0F
    f[4:8] = seq.to_bytes(4, "little")
    f[12:12 + fill] = pn_bytes(seq, fill)
    if tgen:
        crc = TGEN_CRC
    else:
        crc = crc32(bytes(f[0:HDR_BYTES + fill]))   # CRC field still zero here
    if bad_crc:
        crc ^= 0xFFFFFFFF
    f[8:12] = (crc & M32).to_bytes(4, "little")
    if bad_magic:
        f[0] ^= 0xFF            # what TGEN v2's corrupt_every does
    return bytes(f)


def frame_words(img):
    return [int.from_bytes(img[8 * i:8 * i + 8], "little") for i in range(WORDS)]


# --------------------------------------------------------------------------
# golden model of rx_seq_checker, straight from the documented semantics
# --------------------------------------------------------------------------
class Model:
    NAMES = ["frames", "good", "garbage", "crc_fail", "lost_slots", "gap_events",
             "gap1", "gap2", "gap3plus", "dup_or_reorder", "last_seq", "int_last",
             "int_hist_lt30", "int_32", "int_33", "int_other"]

    def __init__(self, tgen_mode=True):
        self.tgen_mode = tgen_mode
        self.c = dict((n, 0) for n in self.NAMES)
        self.seq_seen = False
        self.prev_gap_seq = 0
        self.have_prev_gap = False

    def frame(self, img, complete=True):
        """Feed one complete frame image (as the checker would see it)."""
        c = self.c
        c["frames"] += 1
        magic = img[0] == 0x51 and img[1] == 0x4B and \
            (img[2] | ((img[3] & 0x0F) << 8)) <= 1516
        inorder = False
        if not magic:
            c["garbage"] += 1
        else:
            seq = int.from_bytes(img[4:8], "little")
            exp = (c["last_seq"] + 1) & M32
            if not self.seq_seen:
                inorder = True
            elif seq == exp:
                inorder = True
            elif seq > exp:
                gs = seq - exp
                c["lost_slots"] += gs
                c["gap_events"] += 1
                c["gap1" if gs == 1 else "gap2" if gs == 2 else "gap3plus"] += 1
                if self.have_prev_gap:
                    iv = seq - self.prev_gap_seq
                    c["int_last"] = iv
                    if iv < 30:
                        c["int_hist_lt30"] += 1
                    elif iv == 32:
                        c["int_32"] += 1
                    elif iv == 33:
                        c["int_33"] += 1
                    else:
                        c["int_other"] += 1
                self.prev_gap_seq = seq
                self.have_prev_gap = True
            else:
                c["dup_or_reorder"] += 1
            c["last_seq"] = seq
            self.seq_seen = True
        if not complete:
            return
        # verdict
        if magic:
            fill = img[2] | ((img[3] & 0x0F) << 8)
            fld = int.from_bytes(img[8:12], "little")
            if self.tgen_mode:
                ok = fld == TGEN_CRC
            else:
                zeroed = bytearray(img[0:HDR_BYTES + fill])
                zeroed[8:12] = b"\0\0\0\0"
                ok = fld == crc32(bytes(zeroed))
            if ok:
                if inorder:
                    c["good"] += 1
            else:
                c["crc_fail"] += 1

    def vec(self):
        return [self.c[n] for n in self.NAMES]


# --------------------------------------------------------------------------
# the scripted pattern
# --------------------------------------------------------------------------
def script_tgen():
    """(list of frame images, model) for the tgen_mode pass.

    Intervals are EMITTED-frame seq deltas (operator ruling 2026-09-03).  After
    a gap revealed at seq s, emitting k frames and then skipping j seq numbers
    puts the next gap's revealing frame at seq s+k+1+j, i.e. interval k+1+j --
    so an interval of 32 can be built WITH intervening losses (j = 2), which is
    the case the ruling explicitly asks the tests to cover.

    Covered: in-order run, lost 1 / lost 2 / lost 5, a duplicate, a
    magic-corrupted frame, a CRC-corrupted frame, and gap events at emitted
    intervals 6, 30, 2, 32, 33, 40 -> one entry in each of int_hist_lt30 (x2),
    int_32, int_33 and int_other (x2).
    """
    frames = []
    seq = 1

    def emit(**kw):
        nonlocal seq
        frames.append(build_frame(seq, **kw))
        seq += 1

    def emit_n(n, **kw):
        for _ in range(n):
            emit(**kw)

    def skip(n):
        nonlocal seq
        seq += n

    # A: 5 in-order frames (seq 1..5)
    emit_n(5)
    # B: lose 1 slot -> gap1 (#1, the reference gap: not binned)
    skip(1); emit()
    # C: k=3, j=2 -> gap2, emitted interval 3+1+2 = 6            -> lt30
    emit_n(3); skip(2); emit()
    # D: k=24, j=5 -> gap3plus, emitted interval 24+1+5 = 30     -> int_other
    emit_n(24); skip(5); emit()
    # E: duplicate the last seq (dup_or_reorder += 1, no gap)
    frames.append(build_frame(seq - 1))
    # F: a magic-corrupted frame (garbage; out of the seq tracking entirely)
    frames.append(build_frame(seq, bad_magic=True)); seq += 1
    # G: a CRC-corrupted frame.  Magic ok -> seq tracked; F's slot shows as a
    #    gap of 1, so this is gap #4 at emitted interval 2       -> lt30
    emit(bad_crc=True)
    # H: k=29, j=2 -> gap2, emitted interval 29+1+2 = 32         -> int_32
    #    (32 WITH two intervening lost frames: the ruling's key case)
    emit_n(29); skip(2); emit()
    # I: k=31, j=1 -> gap1, emitted interval 31+1+1 = 33         -> int_33
    emit_n(31); skip(1); emit()
    # J: k=36, j=3 -> gap3plus, emitted interval 36+1+3 = 40     -> int_other
    emit_n(36); skip(3); emit()

    m = Model(tgen_mode=True)
    for f in frames:
        m.frame(f)
    return frames, m


def script_skip(n=5, nframes=60):
    """The exact frame stream qpsk_traffic_gen_v2 emits with skip_every = n.

    Frame i (1-based) carries seq; after every n-th frame seq advances by 2
    instead of 1.  End-to-end check of the derived calibration
    int_last == n + 1 (skip_every removes a seq number, not a stream slot).
    """
    frames = []
    seq = 1
    for i in range(1, nframes + 1):
        frames.append(build_frame(seq))
        seq += 2 if i % n == 0 else 1
    m = Model(tgen_mode=True)
    for f in frames:
        m.frame(f)
    return frames, m


def script_corrupt(mm=8, nframes=60):
    """The exact frame stream qpsk_traffic_gen_v2 emits with corrupt_every = mm.

    seq is contiguous; every mm-th frame has header byte 0 XORed with 0xFF.
    End-to-end check of the derived calibration int_last == mm.
    """
    frames = []
    for i in range(1, nframes + 1):
        frames.append(build_frame(i, bad_magic=(i % mm == 0)))
    m = Model(tgen_mode=True)
    for f in frames:
        m.frame(f)
    return frames, m


def script_host():
    """A short tgen_mode=0 pass over real-CRC32 host frames."""
    frames = []
    seq = 1
    for _ in range(6):
        frames.append(build_frame(seq, tgen=False)); seq += 1
    seq += 2                                   # lose 2
    frames.append(build_frame(seq, tgen=False)); seq += 1
    frames.append(build_frame(seq, tgen=False, bad_crc=True)); seq += 1
    for _ in range(3):
        frames.append(build_frame(seq, tgen=False)); seq += 1
    m = Model(tgen_mode=False)
    for f in frames:
        m.frame(f)
    return frames, m


def write_stream(base, frames):
    """Write <base>.hex (one 64-bit word per line) and <base>.usr (0/1 per
    line, 1 on the first word of each frame).  Both are $readmemh-able."""
    with open(base + ".hex", "w") as fh, open(base + ".usr", "w") as fu:
        for img in frames:
            for i, w in enumerate(frame_words(img)):
                fh.write("%016x\n" % w)
                fu.write("%d\n" % (1 if i == 0 else 0))


def write_exp(path, model):
    """16 counter values, hex, in cnt0..cnt15 order (see Model.NAMES)."""
    with open(path, "w") as fh:
        for v in model.vec():
            fh.write("%08x\n" % v)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)

    fr, m = script_tgen()
    write_stream(os.path.join(out, "tgen"), fr)
    write_exp(os.path.join(out, "tgen_exp.hex"), m)

    # a small extra stream, used for the freeze / clear / mid-frame tests
    extra = [build_frame(s) for s in range(1, 8)]
    write_stream(os.path.join(out, "extra"), extra)

    fs, ms = script_skip(SKIP_N, 60)
    write_stream(os.path.join(out, "skip"), fs)
    write_exp(os.path.join(out, "skip_exp.hex"), ms)
    assert ms.c["int_last"] == SKIP_N + 1, ms.c["int_last"]
    assert ms.c["gap1"] == ms.c["gap_events"]

    fc, mc = script_corrupt(CORR_M, 60)
    write_stream(os.path.join(out, "corrupt"), fc)
    write_exp(os.path.join(out, "corrupt_exp.hex"), mc)
    assert mc.c["int_last"] == CORR_M, mc.c["int_last"]
    assert mc.c["garbage"] == 60 // CORR_M

    fh_, mh = script_host()
    write_stream(os.path.join(out, "host"), fh_)
    write_exp(os.path.join(out, "host_exp.hex"), mh)

    with open(os.path.join(out, "sizes.hex"), "w") as fh:
        for n in (len(fr), len(extra), len(fh_), len(fs), len(fc)):
            fh.write("%08x\n" % (n * WORDS))

    print("GEN_FRAMES_SKIP n=%d int_last=%d gap1=%d gap_events=%d" %
          (SKIP_N, ms.c["int_last"], ms.c["gap1"], ms.c["gap_events"]))
    print("GEN_FRAMES_CORRUPT m=%d int_last=%d garbage=%d" %
          (CORR_M, mc.c["int_last"], mc.c["garbage"]))
    print("GEN_FRAMES_OK tgen_frames=%d extra_frames=%d host_frames=%d" %
          (len(fr), len(extra), len(fh_)))
    print("tgen expect: " + ", ".join("%s=%d" % (n, v)
                                      for n, v in zip(Model.NAMES, m.vec())))
    print("host expect: " + ", ".join("%s=%d" % (n, v)
                                      for n, v in zip(Model.NAMES, mh.vec())))


if __name__ == "__main__":
    main()
