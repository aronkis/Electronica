% run_lna_evm.m -- score mode-3 EVM for lna1 baseline vs lna0, append CSV, print delta.
addpath('/mnt/onetb/scratch/qpsk-jupiter-modem/evm');
cfg = evm_config_240k();
base = '/mnt/onetb/scratch/qpsk-jupiter-modem/two_jup/evmcap';
d = dir(fullfile(base,'*_rev_lna1')); L1 = fullfile(base, d(end).name);
d = dir(fullfile(base,'*_rev_lna0')); L0 = fullfile(base, d(end).name);
fprintf('L1=%s\nL0=%s\n', L1, L0);

opt = struct('plot', false);
T1 = evm_report(L1, cfg, opt);   % appends rows to evm/evm_results.csv
T0 = evm_report(L0, cfg, opt);

getm3 = @(T) T(strcmp(T.mode,'3'), :);
r1 = getm3(T1); r0 = getm3(T0);
fprintf('\n==== REVERSE mode-3 EVM: LNA-on (lna1) vs LNA-off (lna0) ====\n');
fprintf('lna1 rms=%.3f%% mag=%.3f phase=%.3f excised=%.3f  (%s)\n', r1.rms_evm, r1.mag_evm, r1.phase_evm, r1.evm_excised, r1.notes{1});
fprintf('lna0 rms=%.3f%% mag=%.3f phase=%.3f excised=%.3f  (%s)\n', r0.rms_evm, r0.mag_evm, r0.phase_evm, r0.evm_excised, r0.notes{1});
fprintf('DELTA rms(lna0-lna1)=%+.3f%%  mag=%+.3f  phase=%+.3f\n', ...
    r0.rms_evm-r1.rms_evm, r0.mag_evm-r1.mag_evm, r0.phase_evm-r1.phase_evm);
fprintf('(reverse repeatability sigma from EVM_BUDGET = 0.097%%; |delta|>~0.2%% is real)\n');
