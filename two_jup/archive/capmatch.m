G=load('/mnt/onetb/scratch/qpsk_variants/k5_240/golden_k5.mat');
caps=uint32([hex2dec('C00A61C0') hex2dec('600530E0') hex2dec('B0029870') hex2dec('728E29B0') hex2dec('7600530E') hex2dec('3B002987')]);
skips=[0 1 2 4 5 6];
streams={'info',double(G.info(:))'; 'payload_il',double(G.payload(:))'; 'coded',double(G.coded(:))'};
for si=1:numel(caps)
  cb=double(bitget(caps(si),1:32));
  for st=1:size(streams,1)
    s=streams{st,2}; name=streams{st,1};
    for inv=[0 1]
      t=s; if inv, t=1-t; end
      tt=[t t(1:40)];
      for off=1:numel(t)
        if isequal(tt(off:off+31), cb)
          fprintf('skip=%d cap=%08X MATCHES %s inv=%d at offset %d\n', skips(si), caps(si), name, inv, off);
        end
      end
    end
  end
end
fprintf('search done\n');
