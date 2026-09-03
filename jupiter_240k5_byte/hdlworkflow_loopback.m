%--------------------------------------------------------------------------
% HDL Workflow Script
% Generated with MATLAB 25.2 (R2025b) at 12:58:46 on 21/05/2026
% This script was generated using the following parameter values:
%     Filename  : 'C:\work\datalink\TransceiverToolbox\trx_examples\targeting\QPSKTxRxHDLExample\hdlworkflow_rx_debug.m'
%     Overwrite : true
%     Comments  : true
%     Headers   : true
%     DUT       : 'commhdlQPSKTxRxLoopback/TxRxComposite'
% To view changes after modifying the workflow, run the following command:
% >> hWC.export('DUT','commhdlQPSKTxRxLoopback/TxRxComposite');
%--------------------------------------------------------------------------

%% Load the Model
load_system('commhdlQPSKTxRxLoopback');
set_param('commhdlQPSKTxRxLoopback/TxRxComposite', 'TreatAsAtomicUnit', 'on'); save_system('commhdlQPSKTxRxLoopback',[],'OverwriteIfChangedOnDisk',true);

%% Restore the Model to default HDL parameters
%hdlrestoreparams('commhdlQPSKTxRxLoopback/TxRxComposite');

%% Model HDL Parameters
%% Set Model 'commhdlQPSKTxRxLoopback' HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback', 'ClockRatePipelining', 'off');
hdlset_param('commhdlQPSKTxRxLoopback', 'HDLSubsystem', 'commhdlQPSKTxRxLoopback/TxRxComposite');
hdlset_param('commhdlQPSKTxRxLoopback', 'LUTMapToRAM', 'off');
hdlset_param('commhdlQPSKTxRxLoopback', 'ProjectFolder', 'hdl_prj_jupiter_composite');
hdlset_param('commhdlQPSKTxRxLoopback', 'ReferenceDesign', 'JUPITER (RX & TX, BYTE DMA)');
hdlset_param('commhdlQPSKTxRxLoopback', 'ReferenceDesignParameter', {'project','jupiter_sdr','ref_design','rxtx','preprocess','off','postprocess','off','number_of_inputs','4','number_of_bits','16','number_of_valids','1','multiple','2','HDLVerifierAXI','off','HDLVerifierFDC','JTAG'});
hdlset_param('commhdlQPSKTxRxLoopback', 'SynthesisTool', 'Xilinx Vivado');
hdlset_param('commhdlQPSKTxRxLoopback', 'SynthesisToolChipFamily', 'Zynq UltraScale+');
hdlset_param('commhdlQPSKTxRxLoopback', 'SynthesisToolDeviceName', 'xczu3eg-sfva625-2-e');
hdlset_param('commhdlQPSKTxRxLoopback', 'SynthesisToolPackageName', '');
hdlset_param('commhdlQPSKTxRxLoopback', 'SynthesisToolSpeedValue', '');
hdlset_param('commhdlQPSKTxRxLoopback', 'TargetDirectory', 'hdl_prj_jupiter_composite/hdlsrc');
hdlset_param('commhdlQPSKTxRxLoopback', 'TargetLanguage', 'Verilog');
hdlset_param('commhdlQPSKTxRxLoopback', 'TargetPlatform', 'AnalogDevices JUPITER');
hdlset_param('commhdlQPSKTxRxLoopback', 'Workflow', 'IP Core Generation');

% Set SubSystem HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite', 'ProcessorFPGASynchronization', 'Free running');

% Set Inport HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/adc_validIn', 'IOInterface', 'IP Valid Rx Data IN');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/adc_validIn', 'IOInterfaceMapping', '[0]');

% Set Inport HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/adc_dataInI', 'IOInterface', 'ADRV9002 ADC Data I0 [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/adc_dataInI', 'IOInterfaceMapping', '[0:15]');

% Set Inport HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/adc_dataInQ', 'IOInterface', 'ADRV9002 ADC Data Q0 [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/adc_dataInQ', 'IOInterfaceMapping', '[0:15]');

% Set Inport HDL parameters
% rstCS (carrier-sync reset) exposed as AXI4-Lite so the host can reset the
% carrier synchronizer for a clean re-acquisition (write 1 then 0 to x"110").
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/rstCS', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/rstCS', 'IOInterfaceMapping', 'x"110"');

% Set Inport HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/iq_debug_mux', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/iq_debug_mux', 'IOInterfaceMapping', 'x"10C"');

% Set Inport HDL parameters
% rx_input_select: 1 = ADRV9002 ADC (real RF), 0 = internal Tx-loopback.
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/rx_input_select', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/rx_input_select', 'IOInterfaceMapping', 'x"114"');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Carrier Synchronizer/Delay3', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Carrier Synchronizer/Delay4', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Carrier Synchronizer/Delay6', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/Raise Power to 4/Delay1', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/Raise Power to 4/Delay11', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/Raise Power to 4/Delay3', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/Raise Power to 4/Delay4', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/Raise Power to 4/Delay6', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/Raise Power to 4/Delay7', 'ResetType', 'none');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/No HDL', 'Architecture', 'No HDL');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay11', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay12', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay13', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay15', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay17', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay18', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay25', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay28', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay3', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay36', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay38', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay39', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay4', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay41', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay7', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay8', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Delay9', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Reciprocal/Function Impl/Delay10', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Reciprocal/Function Impl/Delay15', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Reciprocal/Function Impl/Delay16', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Reciprocal/Function Impl/Delay6', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Reciprocal/Function Impl/Delay7', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Reciprocal/Function Impl/Delay8', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Corrector/Reciprocal/Function Impl/Delay9', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Estimator/Delay4', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Estimator/Delay5', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Phase Ambiguity Estimation and Correction/Phase Ambiguity Estimator/Delay9', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared/Delay1', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared/Delay2', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared/Delay3', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared and Moving Sum/Delay1', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared and Moving Sum/Delay2', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared and Moving Sum/Delay3', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared and Moving Sum/Delay4', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Correlator/Magnitude Squared and Moving Sum/Delay6', 'ResetType', 'none');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/FIFO/Validate Input Push Pop/No HDL', 'Architecture', 'No HDL');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/No HDL', 'Architecture', 'No HDL');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Timing Adjust/No HDL', 'Architecture', 'No HDL');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Timing Adjust/No HDL/No HDL', 'Architecture', 'No HDL');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Preamble Detector/Timing Adjust/No HDL/No HDL1', 'Architecture', 'No HDL');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/Interpolation Filter/Delay', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/Interpolation Filter/Delay14', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/Interpolation Filter/Delay15', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/Interpolation Filter/Delay6', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/Interpolation Filter/Delay7', 'ResetType', 'none');

% Set Delay HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/Interpolation Filter/Delay9', 'ResetType', 'none');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/No HDL', 'Architecture', 'No HDL');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/No HDL/No HDL', 'Architecture', 'No HDL');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/Receiver/QPSK Rx/Frequency and Time Synchronizer/Symbol Synchronizer/Rate Handle/FIFO/Validate Input Push Pop/No HDL', 'Architecture', 'No HDL');

% Set Outport HDL parameters

% Set Outport HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/count_out', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/count_out', 'IOInterfaceMapping', 'x"100"');

% Set Outport HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/packets_out', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/packets_out', 'IOInterfaceMapping', 'x"104"');

% Set Outport HDL parameters
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/bit_errors_out', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/bit_errors_out', 'IOInterfaceMapping', 'x"108"');

% --- composite-byte mappings (tx_data_source at x"158": 0x11C = dbg_sentinel) ---
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_data', 'IOInterface', 'Byte Data IN [0:63]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_data', 'IOInterfaceMapping', '[0:63]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_valid', 'IOInterface', 'Byte Valid IN');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_valid', 'IOInterfaceMapping', '[0]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_ready', 'IOInterface', 'Byte Ready OUT');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_ready', 'IOInterfaceMapping', '[0]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_first', 'IOInterface', 'Byte First IN');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_first', 'IOInterfaceMapping', '[0]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_data_source', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_data_source', 'IOInterfaceMapping', 'x"158"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_data', 'IOInterface', 'Byte Data OUT [0:63]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_data', 'IOInterfaceMapping', '[0:63]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_valid', 'IOInterface', 'Byte Valid OUT');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_valid', 'IOInterfaceMapping', '[0]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_last', 'IOInterface', 'Byte Last OUT');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_last', 'IOInterfaceMapping', '[0]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_user', 'IOInterface', 'Byte User OUT');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_user', 'IOInterfaceMapping', '[0]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_ready', 'IOInterface', 'Byte Ready IN');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_rx_ready', 'IOInterfaceMapping', '[0]');
% --- end composite-byte mappings ---

% --- fec_counters_overlay mappings (FEC-Rx debug counters + skip_count) ---
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/dbg_sentinel', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/dbg_sentinel', 'IOInterfaceMapping', 'x"11C"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_descr_in', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_descr_in', 'IOInterfaceMapping', 'x"120"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_frame_start', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_frame_start', 'IOInterfaceMapping', 'x"124"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_vit_reset', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_vit_reset', 'IOInterfaceMapping', 'x"128"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_deint_valid', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_deint_valid', 'IOInterfaceMapping', 'x"12C"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_dec_bits', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_dec_bits', 'IOInterfaceMapping', 'x"130"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_bist_start', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_bist_start', 'IOInterfaceMapping', 'x"134"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/skip_count', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/skip_count', 'IOInterfaceMapping', 'x"138"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cap_in', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cap_in', 'IOInterfaceMapping', 'x"13C"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cap_deint', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cap_deint', 'IOInterfaceMapping', 'x"140"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cap_out', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cap_out', 'IOInterfaceMapping', 'x"144"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cap_cad', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cap_cad', 'IOInterfaceMapping', 'x"14C"');

% --- taps_240k5 mappings (rstCS event counter + CFC estimate) ---
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/rstcs_count', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/rstcs_count', 'IOInterfaceMapping', 'x"150"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cfc_est', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cfc_est', 'IOInterfaceMapping', 'x"154"');

% --- adc_forensic mapping (T8.3 valid-cadence + rail-level forensic) ---
% LEAN: block-existence guard -- self-syncs with the overlay gating in
% assemble (map only what actually got built; no env re-derivation to drift).
if ~isempty(find_system('commhdlQPSKTxRxLoopback/TxRxComposite','SearchDepth',1,'Name','adc_forensic'))
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/adc_forensic', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/adc_forensic', 'IOInterfaceMapping', 'x"15C"');
end
% --- end adc_forensic mapping ---
% --- state-pair registers (iq_debug_tap_overlay: boundary loop-state pairs,
%     packed stored-int I/Q latched every 4096th rail beat) ---
if ~isempty(find_system('commhdlQPSKTxRxLoopback/TxRxComposite','SearchDepth',1,'Name','state_agc_in'))
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/state_agc_in',  'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/state_agc_in',  'IOInterfaceMapping', 'x"160"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/state_agc_out', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/state_agc_out', 'IOInterfaceMapping', 'x"164"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/state_cs_in',   'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/state_cs_in',   'IOInterfaceMapping', 'x"168"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/state_cs_out',  'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/state_cs_out',  'IOInterfaceMapping', 'x"16C"');
end
% --- end state-pair mappings ---
% --- T8.5 canary mappings (canary_instrumentation_overlay: shadow timing
%     loop divergence detectors + strobe forensic + beat counter) ---
if isempty(getenv('QPSK_LEAN'))
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_pdiv_cnt',   'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_pdiv_cnt',   'IOInterfaceMapping', 'x"170"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_pdiv_beat',  'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_pdiv_beat',  'IOInterfaceMapping', 'x"174"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_idiv_beat',  'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_idiv_beat',  'IOInterfaceMapping', 'x"178"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_ip_latch',   'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_ip_latch',   'IOInterfaceMapping', 'x"17C"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_is_latch',   'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/shdw_is_latch',   'IOInterfaceMapping', 'x"180"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/strobe_forensic', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/strobe_forensic', 'IOInterfaceMapping', 'x"184"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/beat_counter',    'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/beat_counter',    'IOInterfaceMapping', 'x"188"');
% --- end T8.5 canary mappings ---
% --- T8.6 canary2 mappings (canary2_overlay: path canary + IC/carrier shadows) ---
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/path_canary',    'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/path_canary',    'IOInterfaceMapping', 'x"18C"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/ic_div_beat',    'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/ic_div_beat',    'IOInterfaceMapping', 'x"190"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/ic_div_cnt',     'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/ic_div_cnt',     'IOInterfaceMapping', 'x"194"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_lf_div_beat', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_lf_div_beat', 'IOInterfaceMapping', 'x"198"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_lf_div_cnt',  'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_lf_div_cnt',  'IOInterfaceMapping', 'x"19C"');
end   % lean: canary regs absent

% --- T8.7 canary4 valid census (0x1A0 was reserved; now cs_vin_cnt) ---
% LEAN: block-existence guard (census stripped in production).
if ~isempty(find_system('commhdlQPSKTxRxLoopback/TxRxComposite','SearchDepth',1,'Name','cs_vin_cnt'))
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_vin_cnt',  'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_vin_cnt',  'IOInterfaceMapping', 'x"1A0"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_vlf_cnt',  'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_vlf_cnt',  'IOInterfaceMapping', 'x"1A4"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_vout_cnt', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cs_vout_cnt', 'IOInterfaceMapping', 'x"1A8"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_rxwords', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/cnt_rxwords', 'IOInterfaceMapping', 'x"1AC"');
end
% byte_fifo_ovf (0x1B0) is a SHIPPED FIFO fix -- always mapped (not debug).
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_fifo_ovf', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/byte_fifo_ovf', 'IOInterfaceMapping', 'x"1B0"');
% --- P1B decision-stage census (0x1B4-0x1C8) -- LEAN strip ---
if ~isempty(find_system('commhdlQPSKTxRxLoopback/TxRxComposite','SearchDepth',1,'Name','p1b_pd_w1'))
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pd_w1', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pd_w1', 'IOInterfaceMapping', 'x"1B4"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pd_w2', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pd_w2', 'IOInterfaceMapping', 'x"1B8"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pd_w3', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pd_w3', 'IOInterfaceMapping', 'x"1BC"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pc_w1', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pc_w1', 'IOInterfaceMapping', 'x"1C0"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pc_w2', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pc_w2', 'IOInterfaceMapping', 'x"1C4"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pa_w1', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/p1b_pa_w1', 'IOInterfaceMapping', 'x"1C8"');
end
% --- end T8.6 canary2 mappings ---
% --- end taps_240k5 mappings ---
% nodescr: pn_phase (0x150) REMOVED -- no descrambler, so no PN-phase register.
% cap_raw (0x148) remains dropped. 0x148/0x150 unused/reserved.
% --- end fec_counters_overlay mappings ---

% --- variant_pre_composite_verif mappings ---
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/host_txI',  'IOInterface', 'IP Data 0 IN [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/host_txI',  'IOInterfaceMapping', '[0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/host_txQ',  'IOInterface', 'IP Data 1 IN [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/host_txQ',  'IOInterfaceMapping', '[0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/host_txValid', 'IOInterface', 'IP Valid Tx Data IN');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/host_txValid', 'IOInterfaceMapping', '[0]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_source_select', 'IOInterface', 'AXI4-Lite');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_source_select', 'IOInterfaceMapping', 'x"118"');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugI',     'IOInterface', 'IP Data 2 OUT [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugI',     'IOInterfaceMapping', '[0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugQ',     'IOInterface', 'IP Data 3 OUT [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugQ',     'IOInterfaceMapping', '[0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugValid', 'IOInterface', 'IP Data Valid OUT');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugValid', 'IOInterfaceMapping', '[0]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugI1',    'IOInterface', 'IP Data 0 OUT [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugI1',    'IOInterfaceMapping', '[0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugQ1',    'IOInterface', 'IP Data 1 OUT [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/debugQ1',    'IOInterfaceMapping', '[0:15]');
% --- end variant_pre_composite_verif ---

% Set Outport HDL parameters

% Set Outport HDL parameters

% Set Outport HDL parameters

% Set Outport HDL parameters

% Set Outport HDL parameters

% Set Outport HDL parameters
% Tx outputs drive the ADRV9002 DAC via the composite ref design's
% ADRV9002 DAC Data I0/Q0 interfaces. In the jupiter_sdr rxtx TCL
% wiring (matlab_processors.tcl ~line 861), sync_output/data_out_tx_*
% connects to axi_adrv9001/dac_1_data_i0/q0; ports.json exposes those
% DUT-side as m_name 'ADRV9002 DAC Data I0/Q0'.
% (Earlier we mapped to 'IP Data 0/1 OUT' which is the rx-group DMA
% capture stream -- it does not reach the DAC, so the cable loopback
% saw no signal.)
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_dataOutI', 'IOInterface', 'ADRV9002 DAC Data I0 [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_dataOutI', 'IOInterfaceMapping', '[0:15]');

hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_dataOutQ', 'IOInterface', 'ADRV9002 DAC Data Q0 [0:15]');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_dataOutQ', 'IOInterfaceMapping', '[0:15]');

% IP Load Tx Data OUT (sync_output/data_valid_in_tx_0) is the DUT's "I
% have data" handshake. In jupiter_sdr's rxtx wiring it goes to
% util_dac_1_upack/fifo_rd_en (a dangling pin once the DMA upack was
% deleted), so it is effectively ignored. Keep mapping for cleanliness.
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_validOut', 'IOInterface', 'IP Load Tx Data OUT');
hdlset_param('commhdlQPSKTxRxLoopback/TxRxComposite/tx_validOut', 'IOInterfaceMapping', '[0]');


%% Workflow Configuration Settings
% Construct the Workflow Configuration Object with default settings
hWC = hdlcoder.WorkflowConfig('SynthesisTool','Xilinx Vivado','TargetWorkflow','IP Core Generation');

% Specify the top level project directory
hWC.ProjectFolder = 'hdl_prj_jupiter_composite';
hWC.AllowUnsupportedToolVersion = true;
hWC.ReferenceDesignToolVersion = '2025.1';
hWC.IgnoreToolVersionMismatch = false;

% Set Workflow tasks to run
hWC.RunTaskGenerateRTLCodeAndIPCore = true;
hWC.RunTaskCreateProject = true;
hWC.RunTaskGenerateSoftwareInterface = true;
hWC.RunTaskBuildFPGABitstream = true;
hWC.RunTaskProgramTargetDevice = false;

% Set properties related to 'RunTaskGenerateRTLCodeAndIPCore' Task
hWC.GenerateIPCoreReport = true;

% Set properties related to 'RunTaskCreateProject' Task
hWC.Objective = hdlcoder.Objective.None;
hWC.AdditionalProjectCreationTclFiles = '';
hWC.EnableIPCaching = false;

% Set properties related to 'RunTaskGenerateSoftwareInterface' Task
hWC.GenerateSoftwareInterfaceModel = false;
hWC.OperatingSystem = 'Linux';
hWC.HostTargetInterface = 'Ethernet';
hWC.GenerateHostInterfaceModel = false;
hWC.GenerateHostInterfaceScript = false;

% Set properties related to 'RunTaskBuildFPGABitstream' Task
hWC.RunExternalBuild = false;
hWC.EnableDesignCheckpoint = false;
hWC.TclFileForSynthesisBuild = hdlcoder.BuildOption.Custom;
%hWC.CustomBuildTclFile = 'C:\work\datalink\TransceiverToolbox\CI\scripts\adi_build.tcl';
hWC.CustomBuildTclFile = '/home/tcollins/dev/qpsk_ai/TransceiverToolbox/CI/scripts/adi_build.tcl';
hWC.DefaultCheckpointFile = 'Default';
hWC.RoutedDesignCheckpointFilePath = '';
hWC.MaxNumOfCoresForBuild = '';

% Set properties related to 'RunTaskProgramTargetDevice' Task
% hWC.ProgrammingMethod = hdlcoder.ProgrammingMethod.Download;
% hWC.IPAddress = '';
% hWC.SSHUsername = '';
% hWC.SSHPassword = '';

% Validate the Workflow Configuration Object
hWC.validate;

%% Run the workflow -- SPLIT around the cadence RTL patch (RXROOT E11).
%% Stage 1: generate RTL + package the IP core ONLY.
hWC.RunTaskCreateProject = false;
hWC.RunTaskGenerateSoftwareInterface = false;
hWC.RunTaskBuildFPGABitstream = false;
hWC.validate;
hdlcoder.runWorkflow('commhdlQPSKTxRxLoopback/TxRxComposite', hWC, 'Verbosity', 'on');

%% Cadence-agnostic Rx gating on the generated sources AND the packaged IP-core
%% zip (what vivado_insert_ip.tcl consumes). ERRORS OUT (build aborts) unless the
%% patched markers are verified present -- never build unpatched RTL.
% T8 Rsym fix: Rx ingests natively at the right rung; v6 cadence patch must NOT run
% cadence_patch_ipcore('hdl_prj_jupiter_composite', 'jupiter');

%% Stage 2: project + software interface + bitstream from the PATCHED IP core.
hWC.RunTaskGenerateRTLCodeAndIPCore = false;
hWC.RunTaskCreateProject = true;
hWC.RunTaskGenerateSoftwareInterface = true;
hWC.RunTaskBuildFPGABitstream = true;
hWC.validate;
hdlcoder.runWorkflow('commhdlQPSKTxRxLoopback/TxRxComposite', hWC, 'Verbosity', 'on');
