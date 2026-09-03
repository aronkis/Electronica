function build_rcv_harness(S)
% build_rcv_harness -- standalone harness around the DEPLOYED on-chip Rx
% commhdlQPSKTxRxLoopback/TxRxComposite/Receiver (the FEC one: nodescr,
% deint->Viterbi->RxAlign->BIST, caps, skip_count). Drives dataInI/Q at
% 1/15.36e6 (the RT_Rx rate; internal Downsample/UpsamplesRx=2 -> QPSK Rx 4 sps
% at native 1.92 Msym), reads BIST (packets_out/bit_errors_out) + cap_in/cap_out.
% This is the PROVEN faithful path (gen_stim recipe decoded golden 0%).
%   S.gI,S.gQ : int16 dataInI/Q at 15.36MHz (ZOH x2 of 7.68MHz baseband)
%   S.skip    : skip_count (uint32)
%   S.rstPulseN: leading rstCS-high samples
kitND='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_nodescr';
comp_src='commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(comp_src), load_system(fullfile(kitND,[comp_src '.slx'])); end
% Run the composite InitFcn FAITHFULLY (like the proven build_rx_harness_instr).
% The InitFcn (commhdlQPSKTxRxModelInit) uses qpskFindTxInputData(gcs); make the
% composite the current system so gcs resolves, then run it in base. This sets
% UpsamplesRx/Rsym/Config/latencies/stopTime EXACTLY as the deployed model needs
% (missing these was why the extracted Receiver front-end never acquired).
set_param(0,'CurrentSystem',comp_src);
try
  evalin('base', get_param(comp_src,'InitFcn'));
catch me
  fprintf('  [warn] composite InitFcn: %s -- seeding minimal vars\n', me.message);
  assignin('base','UpsamplesRx',2); assignin('base','UpsamplesTx',1);
  assignin('base','Rsym',1.92e6); assignin('base','Config',commhdlQPSKTxRxParameters());
end

h='rcv_harness'; if bdIsLoaded(h), close_system(h,0); end
new_system(h); load_system(h);
dut=[h '/DUT'];
add_block([comp_src '/TxRxComposite/Receiver'], dut, 'Position',[400 40 760 640]);

% SIM-ONLY: stub the disp-of-decoded-string branch in the BIST msgdec (UTF-8->16
% codegen error on garbage). BIST count/packets/errors math preserved bit-exact.
try
  rt=sfroot; cdb=[h '/DUT/Capture Data Bits/MATLAB Function'];
  ch=rt.find('-isa','Stateflow.EMChart','Path',cdb);
  if ~isempty(ch)
    scr=ch(1).Script;
    scr=regexprep(scr,'msgarray_dec = char\([^\n]*\n','');
    scr=regexprep(scr,'N = length\(msgarray_dec\)[^\n]*\n','');
    scr=regexprep(scr,'strAscii_dec = reshape\(msgarray_dec[^\n]*\n','');
    scr=regexprep(scr,'msg = char\(bin2dec[^\n]*\n','');
    scr=regexprep(scr,'\s*disp\(msg\);','');
    ch(1).Script=scr;
  end
catch me, fprintf('  [warn] disp-stub: %s\n', me.message); end

ph=get_param(dut,'PortHandles');
N=S.N; Ts=1/15.36e6; t=(0:N-1)'*Ts;
% Match the PROVEN build_rx_harness_instr EXACTLY: 5 Inports at S.Tlvds for
% validIn/dataInI/dataInQ/rstCS/iq_debug_mux. skip_count (port 6) is a static
% AXI config -> drive it with a Constant (NOT an Inport at a different rate,
% which broke rate propagation and killed front-end lock).
% EXACT proven build_rx_harness_instr sample-times: validIn/dataInI/dataInQ at
% Ts; rstCS and iq_debug_mux INHERITED (-1). Forcing rstCS/iq_debug_mux to the
% fast Ts (my earlier bug) broke rate propagation -> front-end never acquired.
inSpec={'validIn','boolean',num2str(Ts,'%.14g');'dataInI','int16',num2str(Ts,'%.14g'); ...
        'dataInQ','int16',num2str(Ts,'%.14g');'rstCS','boolean','-1';'iq_debug_mux','uint32','-1'};
for k=1:size(inSpec,1)
  blk=[h '/' inSpec{k,1}];
  add_block('built-in/Inport',blk,'Port',num2str(k),'Position',[80 40*k 110 40*k+18]);
  set_param(blk,'OutDataTypeStr',inSpec{k,2},'SampleTime',inSpec{k,3});
  add_line(h,[inSpec{k,1} '/1'],sprintf('DUT/%d',k),'autorouting','on');
end
% skip_count (DUT inport 6) as a Constant
skipVal0=uint32(0); if isfield(S,'skip'), skipVal0=uint32(S.skip); end
add_block('built-in/Constant',[h '/skip_const'],'Value',num2str(double(skipVal0)), ...
  'OutDataTypeStr','uint32','SampleTime','-1','Position',[80 40*6 110 40*6+18]);
add_line(h,'skip_const/1','DUT/6','autorouting','on');
% Outports to keep: 2 count_out,3 packets_out,4 bit_errors_out,16 cap_in,17 cap_deint,18 cap_out,
% 11 cnt_frame_start,14 cnt_dec_bits,15 cnt_bist_start
nOut=numel(ph.Outport);
keepIdx=[2 3 4 16 17 18 11 14 15];
keepNm ={'count_out','packets_out','bit_errors_out','cap_in','cap_deint','cap_out','cnt_frame_start','cnt_dec_bits','cnt_bist_start'};
for k=1:nOut
  ki=find(keepIdx==k,1);
  if ~isempty(ki)
    add_block('built-in/Outport',[h '/' keepNm{ki}],'Port',num2str(ki),'Position',[820 40*k 850 40*k+18]);
    add_line(h,sprintf('DUT/%d',k),[keepNm{ki} '/1'],'autorouting','on');
  else
    add_block('built-in/Terminator',sprintf('%s/T%d',h,k),'Position',[820 40*k+700 840 40*k+718]);
    add_line(h,sprintf('DUT/%d',k),sprintf('T%d/1',k),'autorouting','on');
  end
end

set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
  'StopTime',num2str(N*Ts,'%.14g'),'SaveOutput','on','OutputSaveName','yout', ...
  'SaveFormat','Dataset','LoadExternalInput','on','ExternalInput','ds_ext','SignalLogging','off');

% rstCS ALWAYS FALSE by default (match the PROVEN build_rx_harness_instr, which
% locks). A start-of-record rstCS pulse RESETS the carrier sync and blocks
% acquisition -> pkts=0. Only assert if explicitly requested (rstPulseN>0).
rstV=false(N,1); if isfield(S,'rstPulseN')&&S.rstPulseN>0, rstV(1:min(S.rstPulseN,N))=true; end
ds=Simulink.SimulationData.Dataset;
ds=ds.addElement(timeseries(true(N,1),t),'validIn');
ds=ds.addElement(timeseries(int16(S.gI),t),'dataInI');
ds=ds.addElement(timeseries(int16(S.gQ),t),'dataInQ');
ds=ds.addElement(timeseries(rstV,t),'rstCS');
ds=ds.addElement(timeseries(uint32(zeros(N,1)),t),'iq_debug_mux');
assignin('base','ds_ext',ds);
end
