% build_composite_local.m -- run from variant cwd; writes commhdlQPSKTxRxLoopback.slx
% into cwd. Source library commhdlQPSKTxRx.slx is in cwd too.
srcSlx = 'commhdlQPSKTxRx.slx';
dstSlx = 'commhdlQPSKTxRxLoopback.slx';
if exist(dstSlx,'file'), delete(dstSlx); end
copyfile(srcSlx, dstSlx);
fprintf('cloned -> %s\n', dstSlx);

load_system('commhdlQPSKTxRxLoopback'); sys='commhdlQPSKTxRxLoopback';
eval(get_param(sys,'InitFcn'));

for n = {'TxRxComposite','TxRxLoopback'}
  prev = find_system(sys,'SearchDepth',1,'Name',n{1});
  for k=1:numel(prev), delete_block(prev{k}); end
end

loop = [sys '/TxRxComposite'];
add_block('built-in/SubSystem', loop, 'Position',[100 600 280 800]);

in_spec = {
  'adc_validIn',      'boolean', '1/15.36e6'; ...
  'adc_dataInI',      'int16',   '1/15.36e6'; ...
  'adc_dataInQ',      'int16',   '1/15.36e6'; ...
  'rstCS',            'boolean', '1/15.36e6'; ...
  'iq_debug_mux',     'uint32',  '1/15.36e6'; ...
  'rx_input_select',  'boolean', '1/15.36e6'};
for k=1:size(in_spec,1)
  blk = [loop '/' in_spec{k,1}];
  add_block('built-in/Inport', blk, 'Port', num2str(k), ...
            'Position', [30 30+40*k 60 50+40*k]);
  set_param(blk, 'OutDataTypeStr', in_spec{k,2}, 'SampleTime', in_spec{k,3});
end

out_names = {'count_out','packets_out','bit_errors_out', ...
             'debugI','debugQ','debugValid','debugI1','debugQ1', ...
             'tx_dataOutI','tx_dataOutQ','tx_validOut'};
for k=1:numel(out_names)
  add_block('built-in/Outport', [loop '/' out_names{k}], ...
            'Port', num2str(k), 'Position', [800 30+40*k 830 50+40*k]);
end

add_block([sys '/Transmitter'], [loop '/Transmitter'], 'CopyOption','duplicate', 'Position',[300 200 430 350]);
add_block([sys '/Receiver'],    [loop '/Receiver'],    'CopyOption','duplicate', 'Position',[600 200 730 400]);

gp = @(nm,p) get_param([sys '/' nm], p);
make_const = @(name, orig) add_block('built-in/Constant', [loop '/' name], ...
   'Value', gp(orig,'Value'), 'SampleTime','1/15.36e6', ...
   'OutDataTypeStr', gp(orig,'OutDataTypeStr'), 'Position', [150 200 180 220]);
make_const('c_dbg','Debug');   set_param([loop '/c_dbg'],  'Position', [150 210 180 230]);
make_const('c_dataI','Debug1'); set_param([loop '/c_dataI'],'Position', [150 240 180 260]);
make_const('c_dataQ','Debug2'); set_param([loop '/c_dataQ'],'Position', [150 270 180 290]);

add_block('dspsigops/Downsample', [loop '/DS_TxValid'], ...
    'N','1', 'InputProcessing','Elements as channels (sample based)', ...  % T8 RATE FIX: Tx rail = bus 15.36e6 (was N=2 to the old 7.68e6 rail)
    'RateOptions','Allow multirate processing', 'Position',[200 280 230 320]);
add_line(loop, 'adc_validIn/1', 'DS_TxValid/1');
add_line(loop, 'c_dbg/1',       'Transmitter/1');
add_line(loop, 'c_dataI/1',     'Transmitter/2');
add_line(loop, 'c_dataQ/1',     'Transmitter/3');
add_line(loop, 'DS_TxValid/1',  'Transmitter/4');

add_block('dspsigops/Repeat', [loop '/REP_TxI'], ...
    'FactorSource','Dialog parameter','N','2','Nmax','16', ...
    'InputProcessing','Elements as channels (sample based)', ...
    'RateOptions','Allow multirate processing','ic','0', ...
    'Position',[470 220 500 240]);
add_block('dspsigops/Repeat', [loop '/REP_TxQ'], ...
    'FactorSource','Dialog parameter','N','2','Nmax','16', ...
    'InputProcessing','Elements as channels (sample based)', ...
    'RateOptions','Allow multirate processing','ic','0', ...
    'Position',[470 260 500 280]);
add_block('dspsigops/Repeat', [loop '/REP_TxValid'], ...
    'FactorSource','Dialog parameter','N','2','Nmax','16', ...
    'InputProcessing','Elements as channels (sample based)', ...
    'RateOptions','Allow multirate processing','ic','0', ...
    'Position',[470 300 500 320]);
add_line(loop, 'Transmitter/1', 'REP_TxI/1');
add_line(loop, 'Transmitter/2', 'REP_TxQ/1');
add_line(loop, 'Transmitter/4', 'REP_TxValid/1');

add_line(loop, 'REP_TxI/1',     'tx_dataOutI/1');
add_line(loop, 'REP_TxQ/1',     'tx_dataOutQ/1');
add_line(loop, 'REP_TxValid/1', 'tx_validOut/1');

add_block('built-in/Switch', [loop '/MUX_RxI'],     'Criteria','u2 ~= 0', 'Position',[540 215 570 245]);
add_block('built-in/Switch', [loop '/MUX_RxQ'],     'Criteria','u2 ~= 0', 'Position',[540 255 570 285]);
add_block('built-in/Switch', [loop '/MUX_RxValid'], 'Criteria','u2 ~= 0', 'Position',[540 295 570 325]);

add_line(loop, 'adc_dataInI/1',     'MUX_RxI/1');
add_line(loop, 'rx_input_select/1', 'MUX_RxI/2');
add_line(loop, 'REP_TxI/1',         'MUX_RxI/3');
add_line(loop, 'adc_dataInQ/1',     'MUX_RxQ/1');
add_line(loop, 'rx_input_select/1', 'MUX_RxQ/2');
add_line(loop, 'REP_TxQ/1',         'MUX_RxQ/3');
add_line(loop, 'adc_validIn/1',     'MUX_RxValid/1');
add_line(loop, 'rx_input_select/1', 'MUX_RxValid/2');
add_line(loop, 'REP_TxValid/1',     'MUX_RxValid/3');

add_block('built-in/RateTransition', [loop '/RT_RxValid'], ...
    'OutPortSampleTime', '1/15.36e6', 'Position',[590 295 620 325]);
add_block('built-in/RateTransition', [loop '/RT_RxI'], ...
    'OutPortSampleTime', '1/15.36e6', 'Position',[590 215 620 245]);
add_block('built-in/RateTransition', [loop '/RT_RxQ'], ...
    'OutPortSampleTime', '1/15.36e6', 'Position',[590 255 620 285]);
add_line(loop, 'MUX_RxValid/1', 'RT_RxValid/1');
add_line(loop, 'MUX_RxI/1',     'RT_RxI/1');
add_line(loop, 'MUX_RxQ/1',     'RT_RxQ/1');
add_line(loop, 'RT_RxValid/1', 'Receiver/1');
add_line(loop, 'RT_RxI/1',     'Receiver/2');
add_line(loop, 'RT_RxQ/1',     'Receiver/3');

add_line(loop, 'rstCS/1',        'Receiver/4');
add_line(loop, 'iq_debug_mux/1', 'Receiver/5');

add_line(loop, 'Receiver/2', 'count_out/1');
add_line(loop, 'Receiver/3', 'packets_out/1');
add_line(loop, 'Receiver/4', 'bit_errors_out/1');
add_line(loop, 'Receiver/5', 'debugI/1');
add_line(loop, 'Receiver/6', 'debugQ/1');
add_line(loop, 'Receiver/7', 'debugValid/1');
add_line(loop, 'Receiver/8', 'debugI1/1');
add_line(loop, 'Receiver/9', 'debugQ1/1');

killtypes = {'ToFile','ToWorkspace','Scope','XYGraph','SpectrumAnalyzer','ConstellationDiagram'};
nkilled = 0;
for kt = killtypes
  bk = find_system(loop, 'LookUnderMasks','all', 'FollowLinks','on', 'BlockType', kt{1});
  for j=1:numel(bk), delete_block(bk{j}); nkilled=nkilled+1; end
end
fprintf('deleted %d sim-only logging blocks inside composite\n', nkilled);

hdlset_param(sys, 'HDLSubsystem', loop);
save_system(sys);
fprintf('build_composite_local: TxRxComposite saved in cwd.\n');
