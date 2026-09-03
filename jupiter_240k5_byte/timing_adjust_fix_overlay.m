function timing_adjust_fix_overlay(sys, base)
% timing_adjust_fix_overlay -- THE Class-1 fix: Timing Adjust offset tracking.
%
% NAMED MECHANISM (P1B census, session 20260715_203950): at device ticks the
% received symbol stream's frame alignment displaces (peak offsets jump ~32
% samples); Peak Search still finds the Barker every frame, but Timing
% Adjust (a) fires sync at the STALE accepted offset (garbage frame) and
% (b) DISCARDS any fresh peak report that arrives while armed (its arm gate
% is timingOffsetValid & ~armed, and the offset hold enables only on arm) --
% so it stays a frame behind through the episode: ta_sync -807/session,
% 171/213 overlap with frame-start deficits.
%
% FIX (minimal, healthy-path BIT-IDENTICAL): track the freshest report --
%   1. offset hold ('Unit Delay Enabled\nSynchronous3') enable :=
%      timingOffsetValid (was: timingOffsetValid & ~armed)
%   2. armed set ('State Register' data+enable) := timingOffsetValid (same)
% In steady state the report repeats the same offset once per frame while
% disarmed, so both changes are no-ops (gates must stay golden -- verified
% by the full suite). Under displacement TA re-targets immediately: worst
% case one late frame instead of a multi-frame cascade.

if nargin < 1 || isempty(sys),  sys  = bdroot; end
if nargin < 2 || isempty(base), base = sys;    end

rcv = [base '/Receiver'];
qrx = [rcv '/QPSK Rx'];
fts = [qrx '/Frequency and Time Synchronizer'];
ta  = [fts '/Preamble Detector/Timing Adjust'];

holdName = sprintf('Unit Delay Enabled\nSynchronous3');
lopName  = sprintf('Logical\nOperator');

% idempotency: after the fix, the hold's enable comes from the inport
lhHold = get_param([ta '/' holdName], 'LineHandles');
srcBlk = get_param(get_param(lhHold.Inport(2), 'SrcBlockHandle'), 'Name');
if strcmp(srcBlk, 'timingOffsetValid')
    fprintf('timing_adjust_fix_overlay: already applied -- skipping\n');
    return;
end
assert(strcmp(srcBlk, lopName), ...
    'timing_adjust_fix: unexpected hold-enable source %s', srcBlk);

phTov = get_param([ta '/timingOffsetValid'], 'PortHandles');

% 1. offset hold: enable := timingOffsetValid
delete_line(lhHold.Inport(2));
phHold = get_param([ta '/' holdName], 'PortHandles');
add_line(ta, phTov.Outport(1), phHold.Inport(2), 'autorouting','on');

% 2. armed flag: data + enable := timingOffsetValid
lhSR = get_param([ta '/State Register'], 'LineHandles');
for k = 1:2
    srcB = get_param(get_param(lhSR.Inport(k), 'SrcBlockHandle'), 'Name');
    if strcmp(srcB, lopName)
        delete_line(lhSR.Inport(k));
        phSR = get_param([ta '/State Register'], 'PortHandles');
        add_line(ta, phTov.Outport(1), phSR.Inport(k), 'autorouting','on');
    end
end

% the arm-gate Logical Operator may now be fully unloaded; if so terminate it
lhLop = get_param([ta '/' lopName], 'LineHandles');
if all(lhLop.Outport == -1) || isempty(find_system(ta,'SearchDepth',1,'FindAll','on', ...
        'Type','line','SrcBlockHandle',get_param([ta '/' lopName],'Handle')))
    % leave in place; codegen prunes unloaded logic
end

fprintf('timing_adjust_fix_overlay: DONE (TA tracks freshest peak report)\n');
end
