function apply_rxfix(harness, fixName, val)
% apply_rxfix -- apply a candidate Rx acquisition fix to the harness DUT copy
% (rcv_harness/DUT). Operates on the harness only; deployed model/kit untouched.
%   fixName='none'  : baseline (no change)
%   fixName='cfcthr': candidate (B) reset-gating -- set CFOChangeDetectThreshold
%                     (the CFO step-change detector deadband that gates rstCS) to
%                     'val' (baseline 0.0015625; CFC_JUMP_MGMT optimum 0.0125).
if nargin<3, val=[]; end
dut=[harness '/DUT'];
switch fixName
  case 'none'
    return;
  case 'cfcthr'
    cfc=[dut '/QPSK Rx/Frequency and Time Synchronizer/Coarse Frequency Compensator/CFO step change detector'];
    c1=[cfc '/Compare' char(10) 'To Constant'];
    c2=[cfc '/Compare' char(10) 'To Constant1'];
    set_param(c1,'const',sprintf('fi(%.10g,1,22,21)',val));
    set_param(c2,'const',sprintf('fi(%.10g,1,22,21)',-val));
    fprintf('apply_rxfix: cfcthr CFOChangeDetectThreshold -> %.10g\n', val);
  otherwise
    error('unknown fix %s', fixName);
end
end
