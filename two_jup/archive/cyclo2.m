function cyclo2()
fs=1.92e6;
files={'golden_tx.iq','GOLDEN-file(240ksym truth)'; 'txfix_nearend.iq','MODEM near-end'};
figure('visible','off','Position',[0 0 1100 800]);
for k=1:size(files,1)
 fid=fopen(files{k,1},'r'); raw=fread(fid,Inf,'int16'); fclose(fid);
 x=double(raw(1:2:end))+1j*double(raw(2:2:end)); x=x(abs(x)>0); x=x-mean(x); x=x/rms(abs(x));
 [P,f]=pwelch(x,hann(4096),2048,4096,fs,'centered'); Pn=10*log10(P/max(P));
 % occupied bandwidth: -20dB relative to peak, restricted to the main lobe
 above=find(Pn>-20); bw=(f(above(end))-f(above(1)));
 m=abs(x).^2; m=m-mean(m); [Pm,fm]=pwelch(m,hann(8192),4096,8192,fs,'onesided');
 rng=fm>5e4 & fm<9e5; [~,ord]=sort(Pm.*rng,'descend'); tops=fm(ord(1:3));
 fprintf('%-26s occ-BW(-20dB)=%.0f kHz | |x|^2 top-3 lines: %.1f, %.1f, %.1f kHz\n', files{k,2}, bw/1e3, tops(1)/1e3, tops(2)/1e3, tops(3)/1e3);
 subplot(2,2,k); plot(f/1e3,Pn); title([files{k,2} ' Welch PSD']); xlabel('kHz'); ylabel('dB'); grid on; ylim([-50 2]);
 subplot(2,2,k+2); plot(fm/1e3,10*log10(Pm/max(Pm))); title('|x|^2 PSD (symbol-rate line)'); xlabel('kHz'); grid on; xlim([0 600]); hold on; xline(240,'r--');
end
saveas(gcf,'/mnt/onetb/scratch/qpsk_variants/two_jup/cyclo.png');
fprintf('saved cyclo.png (240ksym RRC0.5 -> line@240kHz, occ-BW~360kHz)\n');
end
