#!/usr/bin/env python3
"""tel_export_mat.py <recs.npz> <out.mat> [sym0 nsym]
Bridge: parsed PD telemetry records -> .mat for the Simulink PD replay
harness (pd_harness_k5.m / pd_replay_drive.m). Exports the per-symbol
arrays plus a beat-accurate drive schedule:
  drive_dI/dQ  int16   one entry per symbol record
  drive_beats  int32   beats consumed by that symbol (P1D beat field;
                       8 assumed where the field is absent/saturated)
  <every record field> as a column vector
Optional sym0/nsym crop by symCtr (default: all records)."""
import sys
import numpy as np
from scipy.io import savemat

npz, out = sys.argv[1], sys.argv[2]
z = dict(np.load(npz))
if len(sys.argv) > 4:
    s0, n = int(sys.argv[3]), int(sys.argv[4])
    m = (z['symCtr'] >= s0) & (z['symCtr'] < s0 + n)
    z = {k: v[m] for k, v in z.items()}
beats = z.get('beat', np.full(len(z['symCtr']), -1)).astype(np.int32)
beats = np.where((beats <= 0), 8, beats)   # absent/saturated -> nominal 8
exp = {k: np.asarray(v).reshape(-1, 1) for k, v in z.items()}
exp['drive_dI'] = z['dI'].astype(np.int16).reshape(-1, 1)
exp['drive_dQ'] = z['dQ'].astype(np.int16).reshape(-1, 1)
exp['drive_beats'] = beats.reshape(-1, 1)
savemat(out, exp, do_compression=True)
sys.stderr.write(f'{len(beats)} records -> {out}\n')
