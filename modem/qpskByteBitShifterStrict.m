function [bit, pop, state] = qpskByteBitShifterStrict(state, enable, start, word, wordAvail, wordFirst)
% qpskByteBitShifterStrict -- f1536 variant of qpskByteBitShifter with a
% START-BEAT MARKER RE-CHECK (TXMUX task 2026-07-25).
%
% DEFECT FIXED (aggravator of the R0 f1536 byte-plane failure): the legacy
% shifter validates wordFirst only while UNALIGNED. Once aligned, it latches
% blindly at every start; because steady-state consumption (PayloadWords64
% words/frame) exactly equals the host supply, ANY acquired word-phase error
% (e.g. the ingress idle-exit drop, see qpskByteWordBufferSkid.m) persists
% FOREVER -- the silicon "+4 words forever" signature. The k5 cadence
% underflowed often enough to keep realigning; the f1536 gapless keepalive
% queue never does.
%
% FIX: at an aligned `start` beat, the head word MUST carry the first-word
% marker (the host sends one transfer per air frame, tlast-delimited, so
% frame boundary == transfer boundary). If the head is unmarked at start,
% the phase is wrong: discard it and drop to the realign sequence instead of
% latching. Self-heals any offset within <= 1 frame (that frame emits zeros,
% exactly like the legacy underflow path). All other behavior is IDENTICAL
% to qpskByteBitShifter (same state fields, same emission order, same
% mid-frame reload/underflow semantics).
%
% k5-G0 NOTE: NEW function, used only by the f1536 overlay wrapper
% (byte_tx_overlay_k5.m, cfg-gated); qpskByteBitShifter.m and the k5
% generated HDL are untouched (byte-identical).

if nargin == 0
    bit = struct('shiftWord', uint64(0), 'bitIdx', uint8(64), ...
                 'aligned', false);
    return
end

bit = false;
pop = false;

if enable
    if ~state.aligned
        if start && logical(wordAvail) && logical(wordFirst)
            % packet boundary with the first-marked word at the head:
            % latch it and lock alignment
            state.shiftWord = uint64(word);
            pop = true;
            state.bitIdx = uint8(0);
            state.aligned = true;
        elseif logical(wordAvail) && ~logical(wordFirst)
            % discard toward the first-marked word (one per enabled step)
            pop = true;
            state.shiftWord = uint64(0);
            state.bitIdx = uint8(64);
        else
            % head is first-marked (hold for the next start) or FIFO empty
            state.shiftWord = uint64(0);
            state.bitIdx = uint8(64);
        end
    elseif start || state.bitIdx >= 64
        if start && logical(wordAvail) && ~logical(wordFirst)
            % STRICT: frame boundary but the head is NOT a transfer head --
            % word-phase error. Discard and re-run the alignment sequence
            % (zeros this frame; locks to the marker at the next start).
            pop = true;
            state.shiftWord = uint64(0);
            state.bitIdx = uint8(64);
            state.aligned = false;
        elseif wordAvail
            state.shiftWord = uint64(word);
            pop = true;
            state.bitIdx = uint8(0);
        else
            % underflow: emit zeros and re-run the alignment sequence
            state.shiftWord = uint64(0);
            state.bitIdx = uint8(64);
            state.aligned = false;
        end
    end
    if state.aligned
        byteIdx   = bitshift(state.bitIdx, -3);          % floor(bitIdx/8)
        bitInByte = bitand(state.bitIdx, uint8(7));      % mod(bitIdx,8)
        byteVal   = bitand(bitshift(state.shiftWord, -8*int32(byteIdx)), uint64(255));
        bit = bitget(byteVal, uint64(8 - uint64(bitInByte))) > 0;
        state.bitIdx = state.bitIdx + 1;
    end
end
end
