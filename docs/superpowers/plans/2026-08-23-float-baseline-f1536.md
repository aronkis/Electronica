# Float Baseline (f1536) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure what an ideal float receiver achieves on real over-the-air f1536 samples, full chain, so the number is directly comparable to the hardware's own BER on the same signal.

**Architecture:** Port `k5_240/decode_ref_k5.m`'s front end to f1536 geometry and join it to `k5_240/packet_f1536.m`'s already-working back end (`legacy_deinterleave` + `vitdec`, identical trellis and traceback). Score against the ROM reference bits, which `packet_f1536.m` constructs deterministically. Four gates run before any air number is believed.

**Tech Stack:** MATLAB R2025b (`/mnt/onetb/MATLAB/R2025b/bin/matlab`, run headless with `-batch`), Communications Toolbox (`comm.SymbolSynchronizer`, `convenc`, `vitdec`, `poly2trellis`, `rcosdesign`).

**Spec:** `docs/superpowers/specs/2026-08-23-float-baseline-f1536-design.md`

## Global Constraints

- **G1 and G4 are hard stops.** If the synthetic positive control does not decode to **exactly 0 bit errors**, no air number is computed. If float BER on air is **greater than the hardware's 8.2e-5**, the port is wrong and the result is not reported as a channel finding.
- **Metrics rule:** never report a BER or PER without (1) the exact command, (2) the sample/frame count, (3) what is in the denominator. State plainly when a target is NOT confirmed.
- **Report BER and frame recovery separately.** This link has good bits (8.2e-5) and bad frames (13.107 %); collapsing them into one number destroys the finding.
- **No hardware, no rig, no flashing.** Every task here is offline analysis on a banked capture. Do not touch 10.0.0.146 or 10.0.0.148.
- **146 is never flashed.** (Standing project policy; stated for completeness — nothing here goes near it.)
- Git: commit with `git commit -s`. "Commit" implies commit AND push.
- MATLAB emits a `Trial License` banner on every `-batch` run. Harmless; do not treat as an error.

## Reference values (measured, use verbatim)

From `two_jup/r3cap/romair_20260823_115206` (the ROM-on-air capture this plan scores):

```
CAP_START pkts=0x3833 biterr=0x91D8 rstcs=0x0
CAP_END   pkts=0x38CF biterr=0x9313 rstcs=0x0
=> 156 frames, 315 bit errors, ZERO carrier resets  ~= 8.2e-5 BER   <-- the G4 bar
capture: 16,000,000 bytes = 4,000,000 complex int16 samples ~= 81 frames
sample levels: mean|iq| 4004, max 7968, p99 7967 (~1% pinned at ceiling = clipping)
```

## f1536 geometry (confirmed from source, use verbatim)

From `evm/evm_config_1536k.m` and `k5_240/packet_f1536.m`:

```
Rsym = 15.36e6      Sps = 4        Fs = 61.44e6
Beta = 0.5          RrcSpan = 4    -> rcosdesign(0.5, 4, 4)
IdealConstellation  = exp(1i*(pi/4 + (0:3)*(pi/2)))          % pi/4-Gray QPSK
PreambleSymbols     = commhdlQPSKTxRxParameters().preambleSymbols(:)   % 13, SHARED with K5
NPreambleSym = 13   PaySymPerFrame = 12320   FrameLenSym = 12333
DataBitsPerPacket = 24640
trellis = poly2trellis(5,[35 23])   TB = 25    % IDENTICAL to K5
INFO = 12292   TAIL = 4   CODED = 24592   NFILL = 48   PAYLOAD = 24640
ROWS = 1537    COLS = 16                     % CODED == ROWS*COLS
```

**The preamble is shared with K5** — `evm_config_1536k.m:16` states it is "taken from
`commhdlQPSKTxRxParameters()` verbatim". So `decode_ref_k5`'s `preSyms` line carries over
unchanged; only `paySyms` changes.

---

## File Structure

| file | responsibility |
|---|---|
| `k5_240/f1536_ref_bits.m` | (create) Build the f1536 ROM reference: info bits, coded bits, interleaved payload. One job: *what was transmitted.* |
| `k5_240/synth_f1536_waveform.m` | (create) Turn reference payload bits into a clean baseband waveform at sps=4, optionally with AWGN and planted bit faults. One job: *a signal with known content.* |
| `k5_240/float_baseline_f1536.m` | (create) The receiver + scorer. Front end ported from `decode_ref_k5.m`, back end from `packet_f1536.m`. One job: *decode and score.* |
| `k5_240/gates_float_baseline_f1536.m` | (create) G1/G2/G3 runner over synthetic signals. One job: *prove the instrument works before it is used.* |
| `two_jup/SINGLES_CAMPAIGN.md` | (modify) record the result |

Splitting reference-bits from waveform-synthesis matters: G3 plants faults in the
*waveform* while the *reference* must stay pristine. Same file for both invites the bug
where the planted fault silently corrupts the thing it is scored against.

---

## Task 1: f1536 reference bits + synthetic waveform

**Files:**
- Create: `k5_240/f1536_ref_bits.m`
- Create: `k5_240/synth_f1536_waveform.m`

**Interfaces:**
- Produces: `R = f1536_ref_bits()` returning struct with fields `info` (12292x1 double 0/1), `coded` (24592x1), `payload` (24640x1, interleaved + filler), `trellis`, `TB`, `ROWS`, `COLS`, `INFO`, `CODED`, `NFILL`.
- Produces: `[wf, cfg] = synth_f1536_waveform(nFrames, opts)` returning `wf` (complex column, sps=4 baseband) and `cfg` (from `evm_config_1536k()`). `opts` is a struct with optional fields `esn0_db` (scalar, default `Inf` = no noise) and `flipIdx` (vector of 1-based payload-bit indices to flip **per frame**, default `[]`).

- [ ] **Step 1: Write `f1536_ref_bits.m`**

The bit construction is lifted verbatim from `packet_f1536.m` so the two cannot drift.

```matlab
function R = f1536_ref_bits()
%F1536_REF_BITS  The f1536 ROM reference: what the transmitter actually sends.
%
% Bit-for-bit identical construction to packet_f1536.m -- deliberately duplicated
% rather than imported, because packet_f1536.m writes files as a side effect and
% this must be a pure function. If packet_f1536.m ever changes, the assert at the
% end of this function is what catches the drift.

R.trellis = poly2trellis(5,[35 23]);  R.TB = 25;
R.COLS = 16;  R.ROWS = 1537;
R.INFO = 12292;  R.TAIL = 4;  R.CODED = 2*(R.INFO + R.TAIL);   % 24592
R.NFILL = 48;    R.PAYLOAD = R.CODED + R.NFILL;                % 24640
assert(R.CODED == R.ROWS*R.COLS, 'CODED ~= ROWS*COLS');
assert(R.PAYLOAD == 385*64, 'PAYLOAD ~= 385*64');

% message bits: 'ADI Hello World', 8 bits/char, MSB-first
msg = 'ADI Hello World';
msgBits = reshape(de2bi(uint8(msg),8,'left-msb').',[],1);      % 120x1
assert(numel(msgBits)==120);

% PN pad (deterministic seed 15360) + 4 zero tail-pad -> 12292-bit info field
NPAD = 12288 - 120;                                            % 12168
rng(15360,'twister');  pad = randi([0 1],NPAD,1);
R.info = [msgBits; pad; zeros(4,1)];
assert(numel(R.info)==R.INFO);
assert(all(R.info(R.INFO-3:R.INFO)==0), 'the 4 tail-pad info bits must be zero');

% K=5 encode with K-1 zero tail
R.coded = convenc([R.info; zeros(R.TAIL,1)], R.trellis);
assert(numel(R.coded)==R.CODED);

% 1537x16 block interleave, legacy read perm r*COLS + c
il = zeros(R.CODED,1);
for beat = 0:R.CODED-1
    r = mod(beat, R.ROWS);  c = floor(beat / R.ROWS);
    il(beat+1) = R.coded(r*R.COLS + c + 1);
end

% 48-bit PN9 filler (x^9 + x^5 + 1, seed all-ones)
lfsr = ones(9,1);  filler = zeros(R.NFILL,1);
for k = 1:R.NFILL
    fb = xor(lfsr(9), lfsr(5));
    filler(k) = lfsr(9);
    lfsr = [fb; lfsr(1:8)];
end

R.payload = [il; filler];
assert(numel(R.payload)==R.PAYLOAD);
end
```

- [ ] **Step 2: Verify the reference round-trips through the back end**

This is the cheapest possible check that the interleave and encode agree with the decoder
they will be scored by. Run:

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "
R = f1536_ref_bits();
il = R.payload(1:R.CODED);
% inverse permutation: deint perm = c*ROWS + r
deil = zeros(R.CODED,1);
for beat = 0:R.CODED-1
    r = mod(beat, R.ROWS); c = floor(beat / R.ROWS);
    deil(r*R.COLS + c + 1) = il(beat+1);
end
dec = vitdec(deil, R.trellis, R.TB, 'term', 'hard');
fprintf('ROUNDTRIP bit errors = %d (must be 0)\n', sum(dec(1:R.INFO) ~= R.info));
"
```

Expected: `ROUNDTRIP bit errors = 0`.

**If nonzero, STOP.** The interleave convention is wrong and nothing downstream can work.
Do not proceed to Step 3.

- [ ] **Step 3: Write `synth_f1536_waveform.m`**

```matlab
function [wf, cfg] = synth_f1536_waveform(nFrames, opts)
%SYNTH_F1536_WAVEFORM  Clean f1536 baseband at sps=4 with KNOWN content.
%
% Used by the G1/G2/G3 gates. opts.esn0_db (default Inf = noiseless);
% opts.flipIdx = payload-bit indices to flip in EVERY frame (G3 planted fault).
% The reference returned by f1536_ref_bits() is NOT modified -- the fault is
% planted in the transmitted waveform only, so the scorer must find it.
if nargin < 2, opts = struct(); end
if ~isfield(opts,'esn0_db'), opts.esn0_db = Inf; end
if ~isfield(opts,'flipIdx'), opts.flipIdx = []; end

here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..', 'evm'));
cfg = evm_config_1536k();
R   = f1536_ref_bits();

bits = R.payload;
if ~isempty(opts.flipIdx)
    bits(opts.flipIdx) = 1 - bits(opts.flipIdx);
end

% bit pairs -> pi/4-Gray QPSK. Index = 2*b(1) + b(2); the ABSOLUTE mapping does
% not need to match the DUT, because the scorer resolves rotation and I/Q swap
% globally (see float_baseline_f1536.m). What matters is that it is CONSISTENT.
pairs = reshape(bits, 2, []).';
idx   = 2*pairs(:,1) + pairs(:,2);
paySym = cfg.IdealConstellation(idx+1).';
assert(numel(paySym) == cfg.PaySymPerFrame);

oneFrame = [cfg.PreambleSymbols(:); paySym];
assert(numel(oneFrame) == cfg.FrameLenSym);
sym = repmat(oneFrame, nFrames, 1);

% upsample + sqrt-RRC pulse shape at sps=4
up = upsample(sym, cfg.Sps);
rrc = rcosdesign(cfg.Beta, cfg.RrcSpan, cfg.Sps);
wf  = conv(up, rrc, 'same');

if isfinite(opts.esn0_db)
    % Es/N0 on the symbol energy, applied at sample rate
    Es = mean(abs(sym).^2);
    N0 = Es / (10^(opts.esn0_db/10));
    n  = sqrt(N0/2) * (randn(size(wf)) + 1i*randn(size(wf)));
    wf = wf + n;
end
wf = wf(:);
end
```

- [ ] **Step 4: Smoke-test the synthesizer**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "
[wf,cfg] = synth_f1536_waveform(3);
fprintf('samples=%d expected=%d rms=%.4f\n', numel(wf), 3*cfg.FrameLenSym*cfg.Sps, rms(abs(wf)));
"
```

Expected: `samples=147996 expected=147996` and a finite nonzero rms.

- [ ] **Step 5: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add k5_240/f1536_ref_bits.m k5_240/synth_f1536_waveform.m
git commit -s -m "f1536 float baseline: reference bits + synthetic waveform generator

f1536_ref_bits() reproduces packet_f1536's bit construction as a pure function
(packet_f1536.m writes files as a side effect). Interleave round-trip through
vitdec verified at 0 bit errors before anything downstream was built.
synth_f1536_waveform() builds clean sps=4 baseband with known content, plus
AWGN and planted-fault options for the G2/G3 gates."
git push origin per-under-1pct-2026-07
```

---

## Task 2: The receiver — port the front end, join the back end

**Files:**
- Create: `k5_240/float_baseline_f1536.m`

**Interfaces:**
- Consumes: `f1536_ref_bits()` (Task 1), `synth_f1536_waveform(nFrames, opts)` (Task 1).
- Produces: `res = float_baseline_f1536(src, varargin)` where `src` is either a path to an int16 interleaved-IQ capture file **or** a complex column vector (a synthetic waveform). Returns struct with fields:
  - `res.nFrames` — frames decoded
  - `res.bitErrors` — total info-bit errors across decoded frames
  - `res.bitsScored` — total info bits scored (`nFrames * 12292`)
  - `res.ber` — `bitErrors / bitsScored`
  - `res.perFrame` — table: `frame`, `s0`, `errs`, `ok` (errs==0)
  - `res.frameRecovery` — fraction of frames with `errs == 0`
  - `res.hyp` — the winning `(rot, swap)` hypothesis
  - `res.hypStable` — logical, true if the same hypothesis wins on every frame
  - `res.clippedFrac` — fraction of input samples at the int16 tap ceiling (file input only; `NaN` for synthetic)

**Background the implementer needs:**

`decode_ref_k5.m` is self-contained — all seven helpers (`demodDecode`, `framePeaks`,
`fourthPowerCFO`, `coarseCFO`, `deintIndex`, `viterbiDecode`, `refineStarts`) are local
functions in that one 276-line file. **Copy the file, then change the geometry block.**
The K5 decoder resolves quadrant/swap globally by CRC; f1536 ROM frames have no CRC, so
this port resolves by **minimising bit errors against the known reference instead**, with
a stability guard (below).

Note `decode_ref_k5.m` strips zero samples internally (`iq=iq(abs(iq)>0)`). Keep that —
it is the "float leg strips zeros" behaviour `replay_capture.sh` mirrors. On the ROM
capture it is a no-op (0 zero samples measured).

- [ ] **Step 1: Copy the K5 decoder as the starting point**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
cp decode_ref_k5.m float_baseline_f1536.m
```

- [ ] **Step 2: Replace the geometry and contract block**

In `float_baseline_f1536.m`, replace the block that currently reads:

```matlab
C=commhdlQPSKTxRxParameters();
preSyms=C.preambleSymbols(:);
DBPP=C.DataBitsPerPacket; paySyms=DBPP/2; nPre=numel(preSyms); frameLenSym=nPre+paySyms;
sps=8; RRC=rcosdesign(0.5,4,sps);
Fs=1.92e6; Rsym=240e3;
G=load(fullfile(fileparts(mfilename('fullpath')),'golden_k5.mat'));
trellis=G.trellis; TB=G.TB; ROWS=G.ROWS; COLS=G.COLS;
INFO=1084; TAIL=4; CODED=2*(INFO+TAIL); NPAIR=CODED/2;
assert(CODED==2176 && ROWS==136 && COLS==16 && TB==25,'K5 contract constants mismatch');
```

with:

```matlab
here=fileparts(mfilename('fullpath'));
addpath(fullfile(here,'..','evm'));
cfg=evm_config_1536k();
preSyms=cfg.PreambleSymbols(:);          % 13-Barker, SHARED with K5 (evm_config_1536k.m:16)
paySyms=cfg.PaySymPerFrame;              % 12320
nPre=cfg.NPreambleSym;                   % 13
frameLenSym=cfg.FrameLenSym;             % 12333
sps=cfg.Sps;                             % 4
RRC=rcosdesign(cfg.Beta,cfg.RrcSpan,sps);
Fs=cfg.Fs; Rsym=cfg.Rsym;                % 61.44e6 / 15.36e6
REF=f1536_ref_bits();
trellis=REF.trellis; TB=REF.TB; ROWS=REF.ROWS; COLS=REF.COLS;
INFO=REF.INFO; TAIL=REF.TAIL; CODED=REF.CODED; NPAIR=CODED/2;
assert(CODED==24592 && ROWS==1537 && COLS==16 && TB==25,'f1536 contract constants mismatch');
assert(frameLenSym==12333 && paySyms==12320 && sps==4,'f1536 geometry mismatch');
```

The assert is **kept and re-pointed**, not deleted — it is what catches a half-applied port.

- [ ] **Step 3: Accept a synthetic waveform as well as a file**

Replace the capture-read block:

```matlab
fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q));
iq=double(I(1:nn))+1i*double(Q(1:nn)); iq=iq(abs(iq)>0); iq=iq/(max(abs(iq))+eps);
```

with:

```matlab
if isnumeric(capfile) && ~isreal(capfile)
    iq = capfile(:);  clippedFrac = NaN;                 % synthetic waveform
else
    fid=fopen(capfile,'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
    I=raw(1:2:end); Q=raw(2:2:end); nn=min(numel(I),numel(Q));
    iq=double(I(1:nn))+1i*double(Q(1:nn));
    % clipping census BEFORE normalisation -- the ROM capture measured ~1% of
    % samples pinned at the int16 tap ceiling (max 7968, p99 7967). Record it;
    % do not silently absorb it.
    ceilv = max(max(abs(real(iq))), max(abs(imag(iq))));
    clippedFrac = mean(abs(real(iq))>=ceilv | abs(imag(iq))>=ceilv);
    iq=iq(abs(iq)>0); iq=iq/(max(abs(iq))+eps);
end
```

- [ ] **Step 4: Replace CRC-based hypothesis resolution with reference-based**

The K5 file resolves `(rot, swap)` by CRC. Replace that resolution with a sweep scored
against `REF.info`, and record whether the winner is stable across frames:

```matlab
% resolve (rotation, I/Q swap) by MINIMISING bit errors vs the known ROM reference.
% Scored per frame so the winner's STABILITY can be checked: a hypothesis that
% changes frame to frame is fitting noise, not resolving a real ambiguity.
rots = [1, 1i, -1, -1i];  swaps = [0 1];
errsHyp = nan(numel(ps0), numel(rots), numel(swaps));
for k = 1:numel(ps0)
    s0 = ps0(k);
    if s0 < 1 || s0+frameLenSym-1 > numel(symC), continue; end
    fr = symC(s0:s0+frameLenSym-1);
    payD = fr(nPre+1:end);
    for a = 1:numel(rots)
        for b = 1:numel(swaps)
            dec = demodDecode(payD, rots(a), swaps(b), CODED, deintIdx, trellis, NPAIR, TB);
            errsHyp(k,a,b) = sum(dec(1:INFO) ~= REF.info);
        end
    end
end
tot = squeeze(sum(errsHyp, 1, 'omitnan'));
[~, lin] = min(tot(:));  [ai, bi] = ind2sub(size(tot), lin);
res.hyp = struct('rot', rots(ai), 'swap', swaps(bi));
perFrameBest = squeeze(errsHyp(:,ai,bi));
[~, winPerFrame] = min(reshape(errsHyp, size(errsHyp,1), []), [], 2);
res.hypStable = all(winPerFrame(~isnan(perFrameBest)) == lin);
```

- [ ] **Step 5: G1 — the synthetic positive control (HARD STOP)**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "
wf = synth_f1536_waveform(4);
r  = float_baseline_f1536(wf);
fprintf('G1 frames=%d bitErrors=%d ber=%.3e frameRecovery=%.4f hypStable=%d\n', ...
        r.nFrames, r.bitErrors, r.ber, r.frameRecovery, r.hypStable);
"
```

Expected: `bitErrors=0`, `frameRecovery=1.0000`, `hypStable=1`, and `nFrames` ≥ 3
(the first frame may be lost to filter warm-up; that is acceptable, a *zero* frame count
is not).

**If `bitErrors` is nonzero, STOP. Do not run any air capture.** Report the failure with
the per-frame error vector. A clean synthetic waveform that will not decode means a
geometry or convention error, and every downstream number would be meaningless. Likely
culprits, in order: interleave orientation (Task 1 Step 2 should have caught it),
`findpeaks` `MinPeakDistance` scaled for `sps=8`, RRC span at `sps=4`.

- [ ] **Step 6: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add k5_240/float_baseline_f1536.m
git commit -s -m "float_baseline_f1536: f1536 front end joined to packet_f1536's back end

Ported from decode_ref_k5.m (self-contained, all 7 helpers local). Geometry block
re-pointed: sps 8->4, Rsym 240e3->15.36e6, INFO 1084->12292, CODED 2176->24592,
ROWS 136->1537; trellis and TB unchanged. Preamble is shared with K5 verbatim
(evm_config_1536k.m:16). Contract assert kept and re-pointed -- it is what catches
a half-applied port.

Quadrant/swap resolved by minimising bit errors vs the known ROM reference (f1536
ROM frames carry no CRC), with a stability guard: a hypothesis that changes frame
to frame is fitting noise and is reported as hypStable=0.

G1 synthetic positive control: 0 bit errors on a clean waveform."
git push origin per-under-1pct-2026-07
```

---

## Task 3: G2 and G3 — prove the scorer measures and prove it catches

**Files:**
- Create: `k5_240/gates_float_baseline_f1536.m`

**Interfaces:**
- Consumes: `synth_f1536_waveform(nFrames, opts)`, `float_baseline_f1536(src)`, `f1536_ref_bits()`.
- Produces: `gates_float_baseline_f1536()` printing one line per gate and a final `GATES_PASS` or `GATES_FAIL`.

**Why both gates exist:** G2 catches a decoder that runs and emits plausible numbers but is
mis-scaled — precisely how `bs_front_end` failed, returning EVM identical to four
significant figures on two completely different captures. G3 catches a scorer that reports
zero because it is not looking. An instrument that has never caught a planted fault is not
trusted with a zero.

- [ ] **Step 1: Write the gate runner**

```matlab
function gates_float_baseline_f1536()
%GATES_FLOAT_BASELINE_F1536  G1/G2/G3 -- run before any air number is believed.
pass = true;

% ---- G1: synthetic positive control -- clean waveform must be bit-perfect ----
r = float_baseline_f1536(synth_f1536_waveform(4));
g1 = (r.bitErrors == 0) && (r.nFrames >= 3) && r.hypStable;
fprintf('G1 positive control : frames=%d bitErrors=%d hypStable=%d -> %s\n', ...
        r.nFrames, r.bitErrors, r.hypStable, tf(g1));
pass = pass && g1;

% ---- G2: AWGN ladder -- BER must FALL MONOTONICALLY as Es/N0 rises, be high
% at low Es/N0, and reach 0 when clean. A mis-scaled decoder fails this even
% though it "runs": its BER is flat or noise-independent.
esn0 = [0 3 6 9 12];
ber  = nan(size(esn0));
for k = 1:numel(esn0)
    rk = float_baseline_f1536(synth_f1536_waveform(4, struct('esn0_db', esn0(k))));
    ber(k) = rk.ber;
    fprintf('G2 ladder Es/N0=%2d dB : ber=%.3e\n', esn0(k), ber(k));
end
g2 = all(diff(ber) <= 1e-12) && ber(1) > ber(end) && ber(end) < 1e-4;
fprintf('G2 AWGN ladder      : monotonic-decreasing=%d  span %.3e -> %.3e -> %s\n', ...
        all(diff(ber) <= 1e-12), ber(1), ber(end), tf(g2));
pass = pass && g2;

% ---- G3: planted fault -- flip 37 known payload bits per frame; the scorer
% must report a NONZERO error count, and the clean leg must still be zero.
R = f1536_ref_bits();
flip = round(linspace(100, R.CODED-100, 37));
rf = float_baseline_f1536(synth_f1536_waveform(4, struct('flipIdx', flip)));
rc = float_baseline_f1536(synth_f1536_waveform(4));
g3 = (rf.bitErrors > 0) && (rc.bitErrors == 0);
fprintf('G3 planted fault    : planted=%d faulted-run errors=%d clean-run errors=%d -> %s\n', ...
        numel(flip), rf.bitErrors, rc.bitErrors, tf(g3));
pass = pass && g3;

fprintf('%s\n', ternary(pass, 'GATES_PASS', 'GATES_FAIL'));
end

function s = tf(b),        if b, s='PASS'; else, s='FAIL'; end, end
function s = ternary(c,a,b), if c, s=a; else, s=b; end, end
```

**Note on G3's expectation:** the planted bits are *coded* bits, so after Viterbi the
info-bit error count will NOT equal 37 — convolutional decoding both corrects and spreads
errors. The gate therefore asserts **nonzero on the faulted run and zero on the clean
run**, which is the falsifiable claim. Asserting an exact count here would be wrong and
would fail for the right reason at the wrong time.

- [ ] **Step 2: Run the gates**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "gates_float_baseline_f1536"
```

Expected: `GATES_PASS`, with G2 showing BER falling monotonically from a high value at
0 dB to below 1e-4 at 12 dB.

**If any gate fails, STOP and report which one and its numbers.** Do not proceed to the
air capture.

- [ ] **Step 3: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add k5_240/gates_float_baseline_f1536.m
git commit -s -m "G1/G2/G3 gates for the f1536 float baseline

G1 clean waveform must be bit-perfect. G2 AWGN ladder must fall monotonically --
this is what catches a decoder that runs but is mis-scaled, the exact failure mode
of bs_front_end (identical EVM to 4 sig figs on two different captures). G3 plants
37 coded-bit faults per frame and requires nonzero errors on the faulted run with
zero on the clean run; an exact count is NOT asserted because Viterbi both corrects
and spreads coded-bit errors."
git push origin per-under-1pct-2026-07
```

---

## Task 4: G4 — the air measurement and the hardware cross-check

**Files:**
- Modify: `two_jup/SINGLES_CAMPAIGN.md`

**Interfaces:**
- Consumes: `float_baseline_f1536(capturePath)`; capture `two_jup/r3cap/romair_20260823_115206/pair.iq`.

- [ ] **Step 1: Re-run the gates immediately before the air run**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "gates_float_baseline_f1536"
```

Expected `GATES_PASS`. Running them again here is deliberate: it proves the instrument was
healthy *at the moment* the air number was taken, not merely at some earlier commit.

- [ ] **Step 2: Score the ROM-on-air capture**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem/k5_240
/mnt/onetb/MATLAB/R2025b/bin/matlab -batch "
r = float_baseline_f1536('../two_jup/r3cap/romair_20260823_115206/pair.iq');
fprintf('AIR frames=%d bitsScored=%d bitErrors=%d ber=%.3e\n', ...
        r.nFrames, r.bitsScored, r.bitErrors, r.ber);
fprintf('AIR frameRecovery=%.4f hypStable=%d clippedFrac=%.4f\n', ...
        r.frameRecovery, r.hypStable, r.clippedFrac);
"
```

Record every field. `hypStable=0` invalidates the run — it means the rotation/swap winner
changed frame to frame, i.e. the sweep fitted noise rather than resolving an ambiguity.

- [ ] **Step 3: Apply G4 (HARD STOP) and the pre-stated interpretation rule**

**G4:** float BER must be **≤ 8.2e-5** (the hardware's measured BER on this same capture:
315 errors / 156 frames, rstcs=0). Float is the algorithmic ceiling and cannot legitimately
be worse than the fixed-point silicon on that silicon's own samples.

- **float BER > 8.2e-5 → G4 FAILS.** The port is wrong. Report it as an instrument failure,
  **not** as a channel finding. This is exactly the check that would have caught both
  oracles that failed on 2026-08-23.
- **float BER ≈ 0, well below 8.2e-5** → the air samples are algorithmically clean; the
  13.107 % frame loss is implementation gap, not channel. Directs the campaign at the
  ADC→demod ingress stage, which internal loopback bypasses (it injects at the modulator)
  and offline replay bypasses (external-ADC port).
- **float BER ≈ 8.2e-5** → the fixed-point receiver is already at the algorithmic ceiling
  for bit recovery; the frame loss is elsewhere entirely.

- [ ] **Step 4: Record the result**

Append a section to `two_jup/SINGLES_CAMPAIGN.md` containing: the exact commands from
Steps 1–2, the gate output, all `res` fields with the frame and bit counts, the clipped
fraction, the side-by-side against the hardware's 8.2e-5 / 156 frames, which interpretation
rule fired, and — stated plainly — that the capture is ~81 frames and therefore a BER-floor
measurement, too small to bound a 13 % frame-loss rate tightly.

- [ ] **Step 5: Commit**

```bash
cd /mnt/onetb/scratch/qpsk-jupiter-modem
git add two_jup/SINGLES_CAMPAIGN.md
git commit -s -m "G4: float baseline on ROM-on-air data vs the hardware's 8.2e-5

Gates re-run immediately before the air measurement so the instrument is proven
healthy at the moment the number was taken. Reports BER and frame recovery
separately with counts; states which pre-stated interpretation rule fired."
git push origin per-under-1pct-2026-07
```

---

## Self-Review

**Spec coverage:**

| spec requirement | task |
|---|---|
| Port front end to f1536 geometry | Task 2 Step 2 |
| Join to `packet_f1536` back end | Task 1 (reference + interleave), Task 2 Step 2 |
| ROM-on-air capture as input | Task 4 Step 2 |
| G1 synthetic positive control | Task 2 Step 5, re-asserted Task 3 |
| G2 AWGN ladder | Task 3 Step 1 |
| G3 planted fault | Task 3 Step 1 |
| G4 hardware cross-check | Task 4 Step 3 |
| Report BER and frame recovery separately | Task 2 interfaces (`ber`, `frameRecovery`), Task 4 Step 2 |
| Record clipped-sample fraction | Task 2 Step 3 (`clippedFrac`) |
| Interpretation rules stated before the run | Task 4 Step 3 |
| Non-goals (no `bs_front_end` repair, no fixed leg, no `-S`) | Global Constraints; nothing in any task touches them |

**Placeholder scan:** no TBD/TODO. Two runtime substitutions are outputs of earlier steps
and are named as such (the per-frame error vector in Task 2 Step 5's failure path; the
`res` field values in Task 4 Step 4).

**Type consistency:** `f1536_ref_bits()` returns `R` with fields used identically in Tasks
1, 2 and 3 (`R.info`, `R.payload`, `R.CODED`, `R.trellis`, `R.TB`, `R.ROWS`, `R.COLS`,
`R.INFO`). `synth_f1536_waveform(nFrames, opts)` is called with the same signature in Tasks
2 and 3, with `opts.esn0_db` and `opts.flipIdx` spelled consistently.
`float_baseline_f1536(src)` accepts both a path and a complex vector in every call site.
`res` field names (`nFrames`, `bitErrors`, `bitsScored`, `ber`, `frameRecovery`, `hyp`,
`hypStable`, `clippedFrac`) match between the Task 2 interface block and their use in Tasks
3 and 4.

**One risk carried forward, not resolved:** Task 3's G2 asserts monotonic BER decrease
rather than agreement with a theoretical curve. Coded BER at K=5 with interleaving has no
closed form simple enough to assert against without importing a reference curve, and a
wrong reference curve would fail the gate for the wrong reason. Monotonic decrease plus
"high at 0 dB, zero when clean" is the falsifiable claim that is actually defensible.
