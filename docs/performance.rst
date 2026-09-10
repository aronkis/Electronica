Link performance
================

Credited PER, throughput, latency, and the EVM budget on the deployed rung.

Everything on this page is measured on rung **r3** (61.44 MSPS,
15.36 Msym/s, 4 samples/symbol, 1245 frames/s) with the image pair named
in ``images/CURRENT.txt`` and payload whitening on at both ends. Numbers
from the retired 1.92 MSPS rung are not comparable and are not repeated
here.

Packet error rate
-----------------

**Both directions are inside the campaign gate of 1 %, with ARQ off and
lost frames in the denominator.**

.. list-table::
   :header-rows: 1
   :widths: 20 20 34 26

   * - Direction
     - Credited PER
     - Basis
     - Source
   * - forward 146 → 148
     - **0.070–0.079 %**
     - image ``bf2a7305bbe0`` (W1 + R4B + byte-seam census + PAD) with
       ``WHITEN=1``
     - ``images/CURRENT.txt``; ``docs/evidence/RXFIX_STATE.md``
   * - reverse 148 → 146
     - **0.191 % pooled**
     - 3,374 lost of 1,763,538 frames over three credited 487 s legs
       (0.193 / 0.201 / 0.180 %), Clopper-Pearson 95 % upper limit
       0.197 %
     - ``docs/evidence/RXFIX_STATE.md`` Task 37

Four caveats belong beside those numbers whenever they are quoted.

**Lost frames are in the denominator.** The PER is over the
``host_seq``-gap metric, so a frame that never arrived counts as an
error rather than vanishing from the sample. A "PER" computed over
*delivered* frames only is a different and much flatter number.

**The unit of analysis is the run, not the frame.** This link's losses
are bursty, so the Clopper-Pearson interval — which assumes independent
Bernoulli trials — understates the real spread, and pooling frames
across runs lets one lucky run carry a conclusion. The reverse figure is
reported pooled *and* per-leg for exactly that reason; see
:doc:`measurement-discipline`.

**Two of the day's legs were not credited.** They collapsed mid-window
into the open wedge class and are excluded, but their live windows read
0.161 % and 0.156 %, so the honest statement is that all six display-out
windows span 0.156–0.201 %. Excluding a collapsed leg is only legitimate
if you say so and publish what it read.

**The reverse leg is level-limited**, not defect-limited, on the lab
antennas. It is the leg to re-measure first after any antenna work.

For the campaign history behind these numbers — what the loss classes
were, which mechanisms were refuted, and what remains open —
see :doc:`current-state` and ``docs/evidence/RXFIX_STATE.md``.

Throughput and latency
----------------------

The rate-ladder measurements below were taken during the R0/R2/R3 ladder
bring-up and are recorded in ``REPRODUCE.md`` at tag
``archive/pre-cleanup-2026-09-09``; every figure in this section comes
from that file.

.. list-table::
   :header-rows: 1
   :widths: 16 34 22 28

   * - Rung
     - Delivered goodput
     - Average RTT
     - Host CPU
   * - R0 (1.92)
     - 171–182 kbit/s
     - 668 ms
     - 0.24 %
   * - R2 (30.72)
     - 5.29 / 5.83 Mbit/s
     - 28 / 32 ms
     - 8–10 %
   * - **R3 (61.44)**
     - **12.7 forward / 13.7 reverse Mbit/s** — 91–99 % of the
       ~13.9 Mbit/s ceiling
     - 9.5 / 21 ms
     - 8–10 %

The R3 offered-load ladder (1400 B datagrams, delivered RX) reads 5.47 /
5.90 Mbit/s at 6 M offered, 10.55 / 11.86 at 12 M, and 12.73 / 13.72 at
15 M, with loss climbing as the offered rate passes the knee — forward
higher than reverse. One methodological note from that ledger is worth
carrying: the earlier "5.2 Mbit/s at 6 M offered" figure was an
**under-offer artifact**, not a link limit, because 6 M never reached
the knee. Measure the ceiling by walking past it, not by reading one
point below it.

Against the pre-campaign K5 link — roughly 68 kbit/s, a 116 B MTU, and a
polled daemon pinning a core — R3 is about 185–200× the goodput at a
fraction of the CPU, the interrupt-driven DMA path being what removes
the poll spin.

EVM budget
----------

The current-rung EVM work is a **fixed-versus-float budget**, not an RF
decomposition: ``docs/evidence/FLOAT_GAP_BUDGET.md`` quantifies, stage by
stage, where the fixed-point f1536 receiver loses margin against the
float reference on the same healthy captures. Its conclusions are that
on two of three healthy captures the fixed-point chain **beats** float
(by 0.1–2.2 dB); that on the third it is about 2.2–2.5 dB worse, and
that loss lives in the front end's CFO handling rather than in any
stage's quantization; and that the internal per-stage quantization
budget totals only about **0.65 pp EVM** in quadrature from the AGC
output to the recovered constellation. That is the result the campaign
leans on when it says every residual loss is an implementation artifact
rather than a DSP-precision limit (:doc:`system-overview`).

**An absolute RF/SNR EVM decomposition has not been taken on rung r3.**
The one that exists was measured on the retired 240 ksym rung in
2026-07 — it attributed essentially all of the EVM power to the RF and
SNR additive floor, with the forward-only BBDC tick second and the
fabric contributing nothing measurable — and it lives in the retired
EVM budget page, preserved on tag ``archive/pre-cleanup-2026-09-09``. Its
*method* transfers (anchor on the constellation tap, excise tick
episodes, cross-check against the ideal float chain, and gate on a
repeatability run first); its *numbers* do not. Treat this as an
unmeasured item, in the sense :doc:`current-state` uses the term, rather
than as a known quantity.
