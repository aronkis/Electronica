# sel0 / sel2 capture — PRE-REGISTRATION (written 2026-09-01 21:26, BEFORE the arm)

Operator-authorised next arm (2026-09-01): sel0 then sel2, one selector per arm, full gating,
pre-registration + positive control. 146 untouched, no flash, current TXMARK image.
NOT to be armed unattended — hold until the operator is present (07:00 EST 2026-09-02).

## The question
The displacement is confirmed at symbol-sync output (sel3, §72) and transparent downstream.
sel0 (raw RX input) and sel2 (RRC output) are the two untested taps upstream. This arm decides
where the displacement first appears.

## Predictions, written now
- **sel0 displaced by a rung (x4 in the sample domain), single-frame jump, data found in the map:**
  the displacement is present at the very front of the RX chain -> the transmitter / loopback path
  is implicated, not the receiver. STOP the receiver-side search; go to sel8/sel11 (TX taps).
- **sel0 clean (one state at 0, unmatched < 10%), sel2 displaced:** the displacement enters between
  RX input and RRC output — i.e. in AGC or the RRC/decimation path.
- **sel0 clean AND sel2 clean, yet sel3 displaced:** the displacement is created AT symbol sync —
  the interpolator/timing recovery re-anchors the frame. (The forced-kick §76 result says it is not
  a simple loop-integrator drift, so this would point at the interpolation control / NCO phase
  structure, consistent with the half-frame rung geometry.)
- **unmatched > 30% at sel0 or sel2:** the anchor-free method does not read that tap either; report
  as such, do not interpret (the §75 outcome for the index-based method).

## Positive control (required before any sel0/sel2 number counts, §0 rule)
The Task-3 anchor-free scorer must first reproduce §72 on the sel3 capture already on disk
(displaced states at rungs 6363/6240, jump), and score offset-0 on a clean sel5 stretch, BEFORE
the sel0 number is credited. This is being done overnight off-disk; if it fails its controls, the
sel0 arm waits on a scorer fix, not on the rig.

## Capture rules (encoded in beat_tap_capture.sh; see §69/§72 provenance discipline)
One arm per selector; 0x10C set AFTER the arm and verified by effect on 0x20C = golden 0xBCF94856;
capTAP golden before AND after each capture or the capture is void; 1 s polls; host-side stat before
any board-side rm; no retry loop; rig unit via launch_rig_unit.sh.
