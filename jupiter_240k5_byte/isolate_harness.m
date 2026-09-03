function isolate_harness()
% isolate_harness -- decisive test: run MY harness code on the BASE model
% commhdlQPSKTxRx/Receiver (which the PROVEN modemsim harness locks). If MY
% harness locks the base Receiver -> my harness is fine, the FEC-composite
% Receiver is the broken extraction. If not -> my harness code differs from the
% proven one. Uses gen_stim's SCRAMBLED stimulus (base Receiver has descrambler).
repo='/home/tcollins/dev/qpsk_ai/TransceiverToolbox';
kit='/mnt/onetb/scratch/qpsk_variants/fec_jupiter_rxfix';
diary(fullfile(kit,'isolate_harness.log')); diary on; cl=onCleanup(@()diary('off')); %#ok<NASGU>
run(fullfile(repo,'setup.m')); addpath(kit);
addpath('/mnt/onetb/scratch/qpsk_modemsim');
fprintf('==== ISOLATE HARNESS %s ====\n',datestr(now));
% build gen_stim scrambled stimulus (the base Receiver expects scrambled air)
S=gen_stim(30,0);   % S.gI,gQ int16 @15.36MHz, S.Tlvds
% build MY harness but pointed at the BASE model Receiver
sys='commhdlQPSKTxRx';
if bdIsLoaded(sys), close_system(sys,0); end
load_system(sys);   % base model on path (repo copy)
assignin('base','UpsamplesRx',2); assignin('base','UpsamplesTx',1);
assignin('base','Rsym',1.92e6); assignin('base','Config',commhdlQPSKTxRxParameters());
h='iso_harness'; if bdIsLoaded(h), close_system(h,0); end
new_system(h); load_system(h); dut=[h '/DUT'];
add_block([sys '/Receiver'], dut, 'Position',[400 40 760 460]);
% stub disp
try, rt=sfroot; ch=rt.find('-isa','Stateflow.EMChart','Path',[h '/DUT/Capture Data Bits/MATLAB Function']);
  if ~isempty(ch), s=ch(1).Script; s=regexprep(s,'\s*disp\(msg\);',''); s=regexprep(s,'msg = char\(bin2dec[^\n]*\n',''); s=regexprep(s,'msgarray_dec = char\([^\n]*\n',''); s=regexprep(s,'N = length\(msgarray_dec\)[^\n]*\n',''); s=regexprep(s,'strAscii_dec = reshape\(msgarray_dec[^\n]*\n',''); ch(1).Script=s; end
catch, end
N=S.N; Ts=S.Tlvds; t=(0:N-1)'*Ts;
inSpec={'validIn','boolean';'dataInI','int16';'dataInQ','int16';'rstCS','boolean';'iq_debug_mux','uint32'};
for k=1:5
  blk=[h '/' inSpec{k,1}]; add_block('built-in/Inport',blk,'Port',num2str(k),'Position',[80 40*k 110 40*k+18]);
  set_param(blk,'OutDataTypeStr',inSpec{k,2},'SampleTime',num2str(Ts,'%.14g'));
  add_line(h,[inSpec{k,1} '/1'],sprintf('DUT/%d',k),'autorouting','on');
end
ph=get_param(dut,'PortHandles'); nOut=numel(ph.Outport);
keepIdx=[2 3 4]; keepNm={'count_out','packets_out','bit_errors_out'};
for k=1:nOut
  ki=find(keepIdx==k,1);
  if ~isempty(ki), add_block('built-in/Outport',[h '/' keepNm{ki}],'Port',num2str(ki),'Position',[820 40*k 850 40*k+18]); add_line(h,sprintf('DUT/%d',k),[keepNm{ki} '/1'],'autorouting','on');
  else, add_block('built-in/Terminator',sprintf('%s/T%d',h,k),'Position',[820 40*k+500 840 40*k+518]); add_line(h,sprintf('DUT/%d',k),sprintf('T%d/1',k),'autorouting','on'); end
end
set_param(h,'SolverType','Fixed-step','Solver','FixedStepDiscrete','StopTime',num2str(N*Ts,'%.14g'),...
  'SaveOutput','on','OutputSaveName','yout','SaveFormat','Dataset','LoadExternalInput','on','ExternalInput','ds_ext','SignalLogging','off');
rstV=false(N,1);   % rstCS ALWAYS FALSE (match proven build_rx_harness_instr)
ds=Simulink.SimulationData.Dataset;
ds=ds.addElement(timeseries(true(N,1),t),'validIn');
ds=ds.addElement(timeseries(int16(S.gI),t),'dataInI');
ds=ds.addElement(timeseries(int16(S.gQ),t),'dataInQ');
ds=ds.addElement(timeseries(rstV,t),'rstCS');
ds=ds.addElement(timeseries(uint32(zeros(N,1)),t),'iq_debug_mux');
assignin('base','ds_ext',ds);
t0=tic; so=sim(h); dt=toc(t0); y=so.yout;
gv=@(nm) getEl(y,nm);
pk=lastu(gv('packets_out')); er=lastu(gv('bit_errors_out'));
fprintf('BASE Receiver via MY harness: pkts=%d err=%d BER=%.3f%% (%.0fs)\n',pk,er,100*er/max(pk*120,1),dt);
if pk>0, fprintf('=> MY HARNESS LOCKS the base Receiver. The FEC-composite Receiver extraction is what fails.\n');
else, fprintf('=> MY HARNESS does NOT lock even the base Receiver -> harness-code bug vs build_rx_harness_instr.\n'); end
close_system(h,0);
fprintf('==== ISOLATE DONE ====\n');
end
function v=lastu(ts), v=uint32(0); if ~isempty(ts), d=ts.Data; if isinteger(d), v=uint32(d(end)); else, v=uint32(round(double(d(end)))); end, end, v=double(v); end
function el=getEl(y,nm), el=[]; for i=1:numel(y.getElementNames), if strcmp(y{i}.Name,nm), el=y{i}.Values; return; end, end, end
