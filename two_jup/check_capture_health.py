#!/usr/bin/env python3
"""check_capture_health.py <pair.iq> -- is this IQ capture the modem signal, or garbage?

WHY THIS EXISTS (2026-08-24). An entire investigation -- three offline instruments, two of
them wrongly retired, one real bug found and fixed -- was spent debugging receivers that
were being fed captures which did not contain the modem signal at all. The IQ capture DMA
was in the #48 stale-DDR-replay state: it returned a stale ~256-sample buffer on every
read while the modem's own datapath ran normally at 1243 f/s framesync, so every
board-side health check passed.

The decisive tell needed no receiver and no new run: two captures taken FOUR HOURS APART,
in DIFFERENT transmit modes, cross-correlated at 0.9986. Live RX data cannot do that.

Two checks, both cheap, both against a reference that was sitting in the repo the whole
time (two_jup/r3cap/singles_reread/pair.iq, Aug-12, decoded 12/12 CRC-good):

  1. OCCUPIED BANDWIDTH. QPSK with sqrt-RRC beta=0.5 at Rsym=15.36 Msym/s occupies
     ~23 MHz. Measured on the good reference: 22.16 MHz. Measured on every wedged
     capture: 2.88 MHz -- exactly 1/8, and not a subtle difference.
  2. ENVELOPE PERIODICITY. A real signal's envelope autocorrelation at lag>200 sits
     around 0.5. A replayed buffer spikes to ~0.999 at its replay period (256 samples
     observed). This is what catches stale replay specifically.

Run this on EVERY capture before drawing any conclusion from it. Exit 0 = healthy,
1 = degenerate, 2 = usage/read error.
"""
import sys
import numpy as np

FS_HZ = 61.44e6          # tap sample rate
BW_MIN_MHZ = 15.0        # good reference measures 22.16; wedged measures 2.88
BW_MAX_MHZ = 30.0
ENV_CORR_MAX = 0.90      # good reference 0.52; wedged 0.9994
MIN_LAG = 200            # ignore the pulse-shaping correlation at small lags


def load(path, nmax=4_000_000):
    raw = np.fromfile(path, dtype=np.int16, count=2 * nmax)
    if raw.size < 4:
        raise ValueError(f"{path}: too few samples ({raw.size})")
    iq = raw[0::2].astype(np.float64) + 1j * raw[1::2].astype(np.float64)
    r = np.sqrt(np.mean(np.abs(iq) ** 2))
    return iq / r if r > 0 else iq


def occupied_bw_mhz(iq, nfft=65536, nblk=14):
    w = np.hanning(nfft)
    nblk = min(nblk, len(iq) // nfft)
    if nblk < 1:
        raise ValueError("capture too short for a spectrum estimate")
    p = np.zeros(nfft)
    for j in range(nblk):
        seg = iq[j * nfft:(j + 1) * nfft] * w
        p += np.abs(np.fft.fftshift(np.fft.fft(seg))) ** 2
    p /= p.max()
    f = (np.arange(nfft) - nfft // 2) * (FS_HZ / nfft)
    occ = f[p > 0.01]                       # -20 dB
    return (occ.max() - occ.min()) / 1e6


def env_periodicity(iq, nmax=500_000, maxlag=3000):
    e = np.abs(iq[:min(nmax, len(iq))])
    e = e - e.mean()
    n = len(e)
    # normalised autocorrelation via FFT
    nf = 1 << int(np.ceil(np.log2(2 * n)))
    E = np.fft.fft(e, nf)
    ac = np.real(np.fft.ifft(E * np.conj(E)))[:maxlag + 1]
    ac /= ac[0]
    lag = int(np.argmax(ac[MIN_LAG:])) + MIN_LAG
    return lag, float(ac[lag])


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    try:
        iq = load(path)
        bw = occupied_bw_mhz(iq)
        lag, corr = env_periodicity(iq)
    except Exception as exc:                       # noqa: BLE001 - report, do not mask
        print(f"CAPTURE_HEALTH ERROR {path}: {exc}")
        return 2

    bw_ok = BW_MIN_MHZ <= bw <= BW_MAX_MHZ
    env_ok = corr < ENV_CORR_MAX
    ok = bw_ok and env_ok

    print(f"CAPTURE_HEALTH {path}")
    print(f"  occupied BW      = {bw:6.2f} MHz   "
          f"[{BW_MIN_MHZ}..{BW_MAX_MHZ}] -> {'OK' if bw_ok else 'FAIL'}"
          f"   (good ref 22.16, wedged 2.88)")
    print(f"  env periodicity  = {corr:6.4f} at lag {lag:5d}   "
          f"< {ENV_CORR_MAX} -> {'OK' if env_ok else 'FAIL'}"
          f"   (good ref 0.52, wedged 0.9994)")
    if ok:
        print("  VERDICT: HEALTHY -- capture contains the modem signal.")
        return 0
    print("  VERDICT: DEGENERATE -- DO NOT draw conclusions from this capture.")
    if not env_ok:
        print(f"  A near-unity envelope autocorrelation at lag {lag} is the #48 "
              "stale-DDR-replay signature: the DMA is returning a stale buffer.")
        print("  Recovery for that class is REBOOT-ONLY -- a full bring-up restore "
              "does not clear it (verified 2026-08-24).")
    if not bw_ok:
        print("  Bandwidth far from the expected ~23 MHz means the tap is not carrying "
              "the f1536 signal at all.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
