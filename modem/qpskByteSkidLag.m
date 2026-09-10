function lag = qpskByteSkidLag()
% qpskByteSkidLag -- SINGLE SOURCE for the byte_ready pin pipeline depth
% (TXMUX task 2026-07-25). HDL Coder delay balancing inserts an N-deep
% delayMatch register chain between the ByteWordBuffer's registered ready
% (via ReadyDly) and the DUT's byte_ready pin, so the tready the axi_dmac
% acts on is the FIFO's entry-ready delayed by N. qpskByteWordBufferSkid
% gates its push on the same delayed view (readyHist(N)) so source-accept
% and FIFO-store are identical sets; sim_byte_gate_k5.m delays the model
% harness's ready feedback by N to emulate the netlist pin.
%
% N is a CODEGEN ARTIFACT of the current model generation (it changed 4->6
% when FIRPIPE added TX pipeline stages). It is therefore PINNED here and
% ASSERTED against the generated netlist by rtl_sim/run_mm2s_gate.sh
% (which greps the delayMatch chain on byte_ready); the adversarial gate
% additionally fails empirically (drops/dups) on any mismatch. If the
% assertion fires after a model change: re-measure the depth in
% s1_rtl/hdlsrc/commhdlQPSKTxRxLoopback/TxRxComposite.v, update the value
% here, and re-run makehdl + the gates (the depth does not depend on this
% value, so one iteration converges).
%
%#codegen
lag = 8;   % measured on the fixed-branch netlist (delayMatch48_reg[7:0]);
           % pre-fix branch was 6 (delayMatch44), deployed 29b322c4 image was 4.
           % NOTE: qpskByteWordBufferSkid's readyHist is 8 deep -- a future
           % generation with lag > 8 needs that history widened too.
end
