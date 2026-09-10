QPSK Jupiter Modem
==================

**A two-board over-the-air QPSK byte link built from a MATLAB/Simulink
HDL model, running on a pair of ADALM-Jupiter SDRs.**

Two Jupiter boards (10.0.0.146 and 10.0.0.148) each carry an FPGA image
generated from the ``commhdlQPSKTxRxLoopback`` HDL Coder model plus a
platform byte-DMA plane, and exchange 1528-byte frames over the air at
roughly 1245 frames per second in each direction. A single-binary host
daemon (``host/qpsk_tun.c``) turns the link into a Linux TUN
network interface. The campaign goal — delivered packet-error rate
below 1 % in both directions with ARQ off — **is met**, at 0.070–0.079 %
forward and 0.191 % reverse with lost frames in the denominator
(:doc:`performance`). It was reached by treating every residual loss as
an implementation artifact to be found and named, which floating-point
simulation licensed: it decodes the same air captures near-perfectly.

This documentation is written for a competent SDR/FPGA engineer who has
never seen this repository. It is the *map*: the authoritative evidence
lives in the ``docs/evidence/*.md`` investigation ledgers that each page
cites. When a page and a ledger disagree, the ledger wins.

Where to start
--------------

* **Just want a running link?** :doc:`setup-prebuilt` deploys the
  banked pre-built boot images (``images/``) and the host
  daemon with no MATLAB or Vivado involved.
* **New to the project?** Read :doc:`system-overview` first — it defines
  the link, the frame geometry, and the vocabulary every other page
  assumes.
* **Working on the FPGA RX path?** :doc:`byte-plane` maps the byte-plane
  dataflow and the modem register file.
* **Working on the host daemon?** :doc:`host-software` walks
  ``qpsk_tun.c`` and its env-gated instruments, with the RX-drain wedge
  as the worked example.
* **Building or flashing an image?** :doc:`build-and-flash` is the
  pipeline, the image bank, and the safety rails. Do not flash anything
  without reading it.
* **About to measure something?** :doc:`measurement-discipline` is the
  project's epistemics — the habits that kept a months-long debug
  campaign honest, and the ledger of hypotheses they killed.
* **Need to instrument something?** :doc:`debug-instruments` is the
  catalogue of what already exists — host env gates, fabric registers,
  RTL harnesses, analysis tooling — and the known blind spots.
* **Picking up the campaign?** :doc:`current-state` is the snapshot of
  what is solved, what is refuted, and what is open (snapshot 2026-08-15; for everything after, see the update banner on that page).

.. toctree::
   :maxdepth: 2

   setup-prebuilt
   system-overview
   byte-plane
   host-software
   build-and-flash
   measurement-discipline
   debug-instruments
   current-state
   bringup
   provenance
   testing
   performance
   glossary
