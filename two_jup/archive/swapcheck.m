addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
r = soak_decode_k5('gonogo_logs/try1_d2.iq','label','swapchk');
sw = [r.perFrame.swap]; rot = [r.perFrame.rot]; ok = [r.perFrame.infoErr]==0;
fprintf('frames=%d golden=%d | swap=true on %d/%d golden frames | rot histogram (golden): ', numel(sw), sum(ok), sum(sw(ok)), sum(ok));
for rr=[0 90 180 270], fprintf('%d:%d ', rr, sum(rot(ok)==rr)); end; fprintf('\n');
