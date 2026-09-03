function build_composite_harness(S)
% build_composite_harness -- standalone harness around the DEPLOYED on-chip DUT
% commhdlQPSKTxRxLoopback/TxRxComposite (FEC deint->Viterbi->RxAlign->BIST,
% nodescr, caps, skip reg). Drives adc_dataInI/Q with captured air (int16 at the
% ADC LVDS rate), rx_input_select=1 (RF), reads BIST + cap_out.
%   S.gI,S.gQ : int16 column vectors (captured air, scaled)
%   S.Ts      : ADC sample time (s)
%   S.skip    : skip_count value (uint32)
%   S.rstPulseN: number of leading samples to hold rstCS high (0 = none)
kitND='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_nodescr';
comp_src='commhdlQPSKTxRxLoopback';
if ~bdIsLoaded(comp_src), load_system(fullfile(kitND,[comp_src '.slx'])); end
evalin('base', get_param(comp_src,'InitFcn'));

h='comp_harness'; if bdIsLoaded(h), close_system(h,0); end
new_system(h); load_system(h);
dut=[h '/DUT'];
add_block([comp_src '/TxRxComposite'], dut, 'Position',[400 40 760 640]);
ph=get_param(dut,'PortHandles');

% SIM-ONLY harness accommodation: the Receiver's 'Capture Data Bits/MATLAB
% Function' (msgdec) BIST also does disp(char(bin2dec(...))) of the decoded
% string, which trips a UTF-8->UTF-16 codegen error when the decoded bytes are
% garbage. That disp is display-only; the BIST math (count/packets/errors) does
% NOT depend on it. Stub ONLY the disp branch (bit-exact BIST preserved). This
% is on the HARNESS copy; the deployed model/kit is untouched (the HDL does not
% synthesize this display block at all).
try
  rt=sfroot; cdb=[h '/DUT/Receiver/Capture Data Bits/MATLAB Function'];
  ch=rt.find('-isa','Stateflow.EMChart','Path',cdb);
  if ~isempty(ch)
    scr=ch(1).Script;
    % remove the 4 lines inside the elseif that build+disp the decoded string
    scr=regexprep(scr,'msgarray_dec = char\([^\n]*\n','');
    scr=regexprep(scr,'N = length\(msgarray_dec\)[^\n]*\n','');
    scr=regexprep(scr,'strAscii_dec = reshape\(msgarray_dec[^\n]*\n','');
    scr=regexprep(scr,'msg = char\(bin2dec[^\n]*\n','');
    scr=regexprep(scr,'\s*disp\(msg\);','');
    ch(1).Script=scr;
  end
catch me
  fprintf('  [warn] disp-stub: %s\n', me.message);
end
N=S.N; Ts=S.Ts; t=(0:N-1)'*Ts;

% Composite inport order:
% 1 adc_validIn(bool) 2 adc_dataInI(int16) 3 adc_dataInQ(int16) 4 rstCS(bool)
% 5 iq_debug_mux(uint32) 6 rx_input_select(bool) 7 host_txI(int16) 8 host_txQ(int16)
% 9 host_txValid(bool) 10 tx_source_select(uint32) 11 skip_count(uint32)
inSpec={'adc_validIn','boolean',Ts;'adc_dataInI','int16',Ts;'adc_dataInQ','int16',Ts; ...
        'rstCS','boolean',Ts;'iq_debug_mux','uint32',-1;'rx_input_select','boolean',-1; ...
        'host_txI','int16',-1;'host_txQ','int16',-1;'host_txValid','boolean',-1; ...
        'tx_source_select','uint32',-1;'skip_count','uint32',-1};
for k=1:size(inSpec,1)
  blk=[h '/' inSpec{k,1}];
  add_block('built-in/Inport',blk,'Port',num2str(k),'Position',[80 40*k 110 40*k+18]);
  st=inSpec{k,3}; if isequal(st,-1), stStr='-1'; else, stStr=num2str(st,'%.14g'); end
  set_param(blk,'OutDataTypeStr',inSpec{k,2},'SampleTime',stStr);
  add_line(h,[inSpec{k,1} '/1'],sprintf('DUT/%d',k),'autorouting','on');
end

% Outports we keep (indices into composite outports):
% 2 packets_out, 3 bit_errors_out, 1 count_out, 21 cap_out, 19 cap_in, 20 cap_deint,
% 13 cnt_frame_start, 16 cnt_dec_bits, 17 cnt_bist_start
nOut=numel(ph.Outport);
keep=struct('idx',{1,2,3,19,20,21,13,16,17},'name',{'count_out','packets_out','bit_errors_out', ...
    'cap_in','cap_deint','cap_out','cnt_frame_start','cnt_dec_bits','cnt_bist_start'});
kidx=[keep.idx];
for k=1:nOut
  if ismember(k,kidx)
    ki=find(kidx==k,1); nm=keep(ki).name;
    add_block('built-in/Outport',[h '/' nm],'Port',num2str(ki),'Position',[820 40*k 850 40*k+18]);
    add_line(h,sprintf('DUT/%d',k),[nm '/1'],'autorouting','on');
  else
    add_block('built-in/Terminator',sprintf('%s/T%d',h,k),'Position',[820 40*k+700 840 40*k+718]);
    add_line(h,sprintf('DUT/%d',k),sprintf('T%d/1',k),'autorouting','on');
  end
end

Tstop=N*Ts;
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete', ...
  'StopTime',num2str(Tstop,'%.14g'),'SaveOutput','on','OutputSaveName','yout', ...
  'SaveFormat','Dataset','LoadExternalInput','on','ExternalInput','ds_ext', ...
  'SignalLogging','off');

rstV=false(N,1);
if isfield(S,'rstPulseN') && S.rstPulseN>0, rstV(1:min(S.rstPulseN,N))=true; end
skipVal=uint32(0); if isfield(S,'skip'), skipVal=uint32(S.skip); end

ds=Simulink.SimulationData.Dataset;
ds=ds.addElement(timeseries(true(N,1),t),'adc_validIn');
ds=ds.addElement(timeseries(int16(S.gI),t),'adc_dataInI');
ds=ds.addElement(timeseries(int16(S.gQ),t),'adc_dataInQ');
ds=ds.addElement(timeseries(rstV,t),'rstCS');
ds=ds.addElement(timeseries(uint32(zeros(N,1)),t),'iq_debug_mux');
ds=ds.addElement(timeseries(true(N,1),t),'rx_input_select');       % RF/ADC path
ds=ds.addElement(timeseries(int16(zeros(N,1)),t),'host_txI');
ds=ds.addElement(timeseries(int16(zeros(N,1)),t),'host_txQ');
ds=ds.addElement(timeseries(false(N,1),t),'host_txValid');
ds=ds.addElement(timeseries(uint32(zeros(N,1)),t),'tx_source_select');
ds=ds.addElement(timeseries(repmat(skipVal,N,1),t),'skip_count');
assignin('base','ds_ext',ds);
end
