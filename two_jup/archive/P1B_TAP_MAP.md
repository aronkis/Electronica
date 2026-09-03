# P1B tap map -- model-side recon (2026-07-13, agents over kit slx)

Verbatim recon results for the deferred telemetry slots (CFC/PD/FIFO/PC/PA)
and the NCO instrumentation redo. Names with \n contain literal newlines.

```
"p1b": {
      "summary": "Mapped all P1b telemetry tap targets in commhdlQPSKTxRx.slx (kit copy at /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte): CFC Integ Reg/Store Reg/HDL Counter/NCO, Preamble Detector Peak Search registers + FIFO counters + Timing Adjust, Packet Controller pending-SR/end-counter/discard, and Phase Ambiguity counter/accumulator/avgEst — with exact paths (embedded-newline names flagged), BlockTypes, link/mask status, and tap ports.",
      "details": "Source inspected: /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/commhdlQPSKTxRx.slx (kit copy, carries applied overlays), unzipped to /tmp/claude-1000/-home-tcollins-dev-qpsk-ai/f86fec00-4ecb-4ac1-88b1-40de1c8c86d6/scratchpad/slx/txrx; full flattened block tree at .../scratchpad/tree.tsv (1450 blocks). All paths below are relative to model root; prepend 'commhdlQPSKTxRx'. Common prefix RX = Receiver/QPSK Rx/Frequency and Time Synchronizer. NEWLINE WARNING: names written with \
 contain a real newline character — build them with sprintf('...\
...') for find_system/add_line. LinkStatus convention: BlockType=Reference ⇒ library link (get_param LinkStatus='resolved'); tap its OUTPUT port from the parent graph, never add blocks inside it. Plain SubSystems ⇒ LinkStatus='none'. MATLAB Function blocks ⇒ BlockType=SubSystem with SFBlockType='MATLAB Function'; internal persistent state is only reachable by editing the function to add an output.

(1) COARSE FREQUENCY COMPENSATOR — RX/Coarse Frequency Compensator (SubSystem, SID 4872, plain)
- Estimator subsystem: RX/Coarse Frequency Compensator/Coarse Frequency Estimator (SubSystem 4885, plain, no mask).
- Integrator: .../Coarse Frequency Estimator/Integrator (SubSystem 4912, plain). Inside:
  * 'Integ Reg' (SID 4919) — BlockType=Reference, SourceBlock=hdlsllib/Discrete/'Unit Delay Enabled Resettable\
Synchronous' (HDL name Integ_Reg). 3 in (data=Add1, enable=Delay2(validIn), reset=Reset Generator), 1 out. TAP out:1 = running accumulator (feeds Add1 in:2 and Store Reg in:1).
  * 'Store Reg' (SID 4928) — Reference, hdlsllib/Discrete/'Unit Delay Enabled\
Synchronous' (HDL Store_Reg). enable in:2 = Reset Generator pulse (\"store the value in the Reg before reset\"). TAP out:1 = windowed integ snapshot → Integrator outport 1 'IntegOut'.
  * Window counter: .../Integrator/Reset Generator/'HDL Counter' (SID 4925) — Reference, hdlsllib/Sources/HDL Counter (HDL_Counter). Count limited 0..integAvgLen, wordlen nextpow2(integAvgLen+1), enable port=validIn, no reset port. TAP out:1 (single output = count). Reset pulse itself = Reset Generator outport 'reset' (4927) = Delay1(validIn) AND (count==integAvgLen).
  * Held CFO estimate: .../Coarse Frequency Estimator/Extract Frequency/'Unit Delay Enabled\
Synchronous' (SID 4909, Reference hdlsllib) out:1 → 'normFreqOut'. Estimator subsystem outport 'normFreqEst' (4935) carries it up; CFC outport 4 'normalizedFreqEst' (4981) exports it at CFC level.
- NCO: RX/Coarse Frequency Compensator/NCO (SID 4956) — BlockType=Reference, LIBRARY-LINKED to dsphdlsigops2/NCO (DSP HDL Toolbox), SourceType=NCO. 2 in / 2 out: in:1 = phase increment (from 'Data Type Conversion4' 4938), in:2 = valid. out:1 = complex exponential sfix16_En14 → 'Math\
Function' (conj, 4955); out:2 = validOut → 'Terminator' (4977) — out:2 is UNUSED, a free tap. Params: PhaseIncrementSource=Input port, AccumulatorWL=21, quantized to 14 bits, Waveform=Complex exponential, PhasePort=off.
- Also useful: CFC outport 2 'rstCS' (4979) from 'CFO step change detector' (SubSystem 4875, plain — the block patched by the rxfix threshold change).

(2) PREAMBLE DETECTOR — RX/Preamble Detector (SubSystem 5160, plain)
- Peak Search: RX/Preamble Detector/Peak Search (SubSystem 5277, MASKED — self mask w/ param samplesPerFrame, NOT a library link; use find_system(...,'LookUnderMasks','all'); add_block inside is legal). Internals (wiring verified from system_5277.xml):
  * 'timing Reference' (SID 5290) — Reference, hdlsllib HDL Counter, count-limited 0..samplesPerFrame1x-1, enable=validIn. TAP out:1 = intra-window sample index (drives timingOffset capture and window-end compare).
  * 'timing Reference Long' (SID 5291) — Reference, HDL Counter, FREE-RUNNING 32-bit, enable=validIn. TAP out:1 = long timestamp.
  * Running max register: 'Unit Delay Enabled Resettable\
Synchronous' (SID 5288) — Reference hdlsllib. data=corr, enable=(corr>max AND thresholdExceeded) from 'Logical\
Operator4' (5283), reset=window-done (5282). TAP out:1 = current running max (loops to 'Relational\
Operator' 5284 in:2).
  * Sticky success flag: 'Unit Delay Enabled Resettable\
Synchronous1' (SID 5289) → outport 3 'success'.
  * timingOffset hold: 'Unit Delay Enabled\
Synchronous' (SID 5286) — data=timing Reference count, enable=new-peak strobe (5283). out:1 → outport 1 'timingOffset'.
  * Held long timestamp: 'Unit Delay Enabled\
Synchronous1' (SID 5287) — data=timing Reference Long, enable=new-peak strobe; out:1 → 'Terminator' (5285) — UNUSED, free tap (peak timestamp).
  * done pulse = 'Logical\
Operator' (5282) out:1 → outport 2 'done'.
- FIFO: RX/Preamble Detector/FIFO (SubSystem 5227, MASKED — params fifoSize/pushFullDiag/popEmptyDiag, not library-linked). Internals:
  * 'Push Counter' (SID 5234) and 'Pop Counter' (SID 5233) — Reference, hdlsllib HDL Counter, count-limited 0..fifoSize-1, reset+enable ports on (in:1=reset via 'Delay1' 5232, in:2=enable=valid push/pop). TAP out:1 of each = RAM write/read address.
  * Occupancy counter: RX/Preamble Detector/FIFO/Validate Input Push Pop/'MATLAB Function' (SID 5254) — SubSystem, SFBlockType=MATLAB Function (script 'hdlCounter' in chart_116: persistent countReg, up/down via dir). TAP out:1 'count' → 'Delay' (5244) → subsystem outport 3 'numEntries'.
  * FREE taps at Preamble Detector level: FIFO block out:2 'numEntries' → 'Terminator' (5297); out:3 'validPop' → 'Terminator1' (5298). Both currently unused — hijack without touching FIFO internals.
  * 'Simple Dual Port RAM' (5235) — Reference, hdlsllib/HDL RAMs.
- Timing Adjust: RX/Preamble Detector/Timing Adjust (SubSystem 5299, plain). Internals:
  * 'State Register' (SID 5335) — Reference, 'Unit Delay Enabled Resettable\
Synchronous': armed flag, set by timingOffsetValid strobe ('Logical\
Operator' 5309), reset by fired sync (via 'Delay2' 5306). TAP out:1.
  * 'timing Reference' (SID 5337) — Reference, HDL Counter, count-limited 0..searchSamples-1, enable=validIn. TAP out:1.
  * Accepted-offset hold: 'Unit Delay Enabled\
Synchronous3' (SID 5336) — data=timingOffset inport, enable=5309. TAP out:1 (compared against 5337 by 'Relational\
Operator' 5334).
  * Sync fire = 'Logical\
Operator2' (5311) out:1 → 'Delay' 5304 → outport 3 'SyncPulse'.
- Note: Peak Search names 'Unit Delay Enabled\
Synchronous' and Timing Adjust 'timing Reference' collide with names elsewhere — always use full paths.

(3) PACKET CONTROLLER — RX/Packet Controller (SubSystem 4996, plain)
- Pending SR: RX/Packet Controller/'MATLAB Function' (SID 5012) — SubSystem, SFBlockType=MATLAB Function (chart_17: persistent Reg; set on syncPulse, cleared on Reg&&valid). in:1=validIn, in:2=syncPulse. TAP out:1 'out' = pending state (== Reg at step start). Internal Reg itself needs a function edit to expose.
- Start pulse = 'Logical\
Operator' (5011) out:1 (validIn AND pending) → 'Delay2' 5002 → discard controller startIn. KIT COPY ALREADY TAPS IT: → 'To File1' (SID 5785) and 'Time Scope End Generator' (5783) in:2 (existing canary overlay blocks; SIDs 5783-5785 are overlay additions).
- End counter: RX/Packet Controller/End Generator/'HDL Counter' (SID 5008) — Reference, hdlsllib HDL Counter, count-limited, CountMax='1120 -1', reset port on (in:1=rst=start pulse), enable in:2=validIn(delayed). TAP out:1 = position-in-packet 0..1119. End pulse = 'Compare\
To Constant' (5006, const '1120-1') AND valid via 'Logical\
Operator1' (5009) → 'Delay6' (5007) → End Generator outport 'endOut' (5010). At PC level End Generator out:1 already tapped to 'To File' (5784) + scope in kit copy.
- Sample discard: RX/Packet Controller/'sample discard controller' (SID 5013) — SubSystem, SFBlockType=MATLAB Function (chart_54: persistent 'active' gate; zeroes data until startIn, closes on endIn). Ports in: dataIn(1), validIn(2), startIn(3), endIn(4); TAP outs: dataOut(1), startOut(2), endOut(3), validOut(4) — these feed PC outports 5014-5017 directly. Internal 'active' flag not exposed (function edit required).

(4) PHASE AMBIGUITY ESTIMATION AND CORRECTION — RX/Phase Ambiguity Estimation and Correction (SubSystem 5018, plain)
- Estimator counter: .../Phase Ambiguity Estimator/'HDL Counter' (SID 5136) — Reference, hdlsllib HDL Counter, count-limited 0..7 (CountMax='8-1', wordlen 3), reset in:1 = sync-window logic ('Subsystem' 5140 out), enable in:2 = gated valid ('Subsystem1' 5148 out). TAP out:1 = sync-symbol index; '==7' via 'Compare\
To Constant' (5123) makes endOut.
- Averaging accumulator: .../Average Estimates/'Unit Delay Enabled Resettable\
Synchronous' (SID 5036) — Reference hdlsllib. data = 'Add' (5026) out via 'Data Type Conversion1' (5028); enable = validIn via 'Delay1' 5031; reset = endIn via 'Delay2' 5032 → 'Delay3' 5033. TAP out:1 = running sum of 8 estimates (also feeds 'Divide by 8' DTC 5034).
- Held avgEst: .../Average Estimates/'Unit Delay Enabled\
Synchronous' (SID 5035) — Reference hdlsllib. data = sum/8 (5034), enable = endIn (5032). TAP out:1 → 'Data Type Conversion2' (5029) → subsystem outport 'avgEst' (5037), consumed by 'Phase Ambiguity Corrector' (SubSystem 5052) 'estimate' input.
- Estimator outputs available at .../Phase Ambiguity Estimator outports: estOut(2, from 'Product' 5139 via 'Delay9' 5134), endOut(1), validOut(3).

Cross-cutting facts for the overlay script: hierarchy above every target ('Receiver', 'QPSK Rx', 'Frequency and Time Synchronizer', and all four function blocks' parents) is in-model (no library links); only 'QPSK Rx' (SID 1886, icon-only), 'Peak Search' (5277) and both FIFOs (Preamble Detector 5227, Symbol Synchronizer Rate Handle 5479) carry masks ⇒ find_system needs 'LookUnderMasks','all' and mask-workspace vars (fifoSize, samplesPerFrame) resolve inside them. All hdlsllib/dsphdl Reference blocks resolve LinkStatus='resolved'. HDL-name mapping observed: 'Integ Reg'→Integ_Reg, 'Store Reg'→Store_Reg, 'HDL Counter'→HDL_Counter, 'timing Reference'→timing_Reference (space→underscore). Free (terminated/unused) signals ready for zero-risk tapping: CFC NCO out:2, Peak Search 5287 out:1 (held long timestamp), Preamble Detector FIFO numEntries (→Terminator 5297) and validPop (→Terminator1 5298)."
    },
    "nco": {
      "summary": "Both NCOs are DSP HDL Toolbox library blocks (SourceBlock dsphdlsigops2/NCO) with 21-bit accumulators, 14-bit quantized phase, fixdt(1,16,14) complex-exponential outputs, and fixdt(1,21,0) stored-integer phase-increment inputs. The Carrier Synchronizer 'Direct Digital Synthesis' is a plain unmasked subsystem wrapping its NCO (3 in: rst/validIn/phaseInc). A bit-exact 21-bit phase-accumulator replica MLFB is feasible for both; the CS DDS NCO's full complex output is NOT bit-exactly replicable because it has 11 dither bits (internal PRBS, PhasePort off), while the CFC NCO (DitherSource None) is fully replicable.",
      "details": "Source: kit copy /mnt/onetb/scratch/qpsk-jupiter-modem/jupiter_240k5_byte/commhdlQPSKTxRx.slx, extracted to /tmp/claude-1000/-home-tcollins-dev-qpsk-ai/f86fec00-4ecb-4ac1-88b1-40de1c8c86d6/scratchpad/slx/kit_txrx/simulink/systems/. Diffed against the repo original (/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample/commhdlQPSKTxRx.slx, extracted to .../slx/orig_txrx): system_4781 (Carrier Synchronizer), system_4803 (DDS), system_4814 (Loop Filter), system_4872 (CFC) are IDENTICAL except block positions — overlays did not touch this area, so findings apply to both copies.

HIERARCHY (exact names; \
 = embedded newline in block name):
root 'commhdlQPSKTxRx' / 'Receiver' (SID 5836) / 'QPSK Rx' (SID 1886, MASKED subsystem — mask init sets integAvgLen = 2^15 and loads CSLoopFilterPropGain/IntegGain, CFOChangeDetectThreshold etc. from commhdlQPSKTxRxParameters()) / 'Frequency and Time Synchronizer' (SID 4777, system_4777) / then siblings 'Coarse Frequency Compensator' (SID 4872) and 'Carrier Synchronizer' (SID 4781).

(1) 'Direct Digital Synthesis' (SID 4803, system_4803.xml), path .../Carrier Synchronizer/Direct Digital Synthesis:
- Plain BlockType=\"SubSystem\", NO mask, NO library link (fully openable; contents in system_4803.xml).
- Inports (exact names / Port numbers) and their sources inside 'Carrier Synchronizer' (system_4781):
  * 'rst' Port 1 <- 'Logical\
Operator' (SID 4813, BlockType Logic, OutDataTypeStr boolean, AllPortsSameDT off; NO Operator param serialized => default operator AND). Its in:1 <- CS inport 'manualRst' (Port 4; fed at system_4777 level by top inport 'rstCS' SID 4780); in:2 <- 'Loop Filter' out:3 'rst' (= 'internalRst' delayed 2+2+1+2 = 7 cycles). So DDS accumulator reset = manualRst AND delayed(internalRst) — flag this: it is an AND, not OR (the OR is only inside the Loop Filter for its own registers, SID 4839 Operator=OR explicitly serialized, so the missing param on 4813 genuinely means AND; identical in the stock MathWorks model).
  * 'validIn' Port 2 <- 'Loop Filter' out:2 'valid' (boolean, delayed copy of CS validIn).
  * 'phaseInc' Port 3 <- 'Loop Filter' out:1 'v'.

(2) Inside DDS (system_4803): 'phaseInc' -> 'Delay' (SID 4809, DelayLength 1) -> 'Data Type Conversion' (SID 4807: OutDataTypeStr fixdt(1,21,21), RndMeth Floor, SaturateOnIntegerOverflow off = wrap) -> 'Data Type Conversion1' (SID 4808: OutDataTypeStr fixdt(1,21,0), ConvertRealWorld = \"Stored Integer (SI)\" i.e. pure bit reinterpret, Floor, no saturate) -> NCO in:1.
- 'NCO' (SID 4810): BlockType Reference, SourceBlock \"d
```
