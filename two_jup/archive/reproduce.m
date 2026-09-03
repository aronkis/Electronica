% reproduce.m -- apply candidate impairments to the CLEAN golden waveform, decode with the
% validated soak_decode, find which reproduces the ~43% failure. Model-based error repro.
addpath('/home/tcollins/dev/qpsk_ai/TransceiverToolbox/trx_examples/targeting/QPSKTxRxHDLExample');
addpath('/mnt/onetb/scratch/qpsk_variants/k5_240');
g=fopen('/mnt/onetb/scratch/qpsk_variants/two_jup/golden_tx.iq'); raw=fread(g,Inf,'int16'); fclose(g);
x0=double(raw(1:2:end))+1j*double(raw(2:2:end)); fs=1.92e6; n=(0:numel(x0)-1).'; rng(3);
fprintf('\n=== reproduction: impairment on clean golden -> coded BER (target ~43%%) ===\n');
fprintf('baseline (clean golden)      : %.2f%%\n',100*run_ber(x0));
fprintf('+ CFO 4600 Hz                 : %.2f%%\n',100*run_ber(x0.*exp(1j*2*pi*4600/fs*n)));
for snr=[15 10 6]
  fprintf('+ AWGN %2d dB                  : %.2f%%\n',snr,100*run_ber(awgn(x0,snr,'measured')));
end
for st=[1 3 6 12]
  ph=cumsum(st*pi/180*randn(numel(x0),1));
  fprintf('+ phase-walk %2d deg/sample    : %.2f%%\n',st,100*run_ber(x0.*exp(1j*ph)));
end
for ppm=[50 500 5000 50000]
  t=(0:numel(x0)-1); tq=0:(1+ppm*1e-6):t(end); xr=interp1(t,x0,tq,'linear').';
  fprintf('+ clock offset %5d ppm      : %.2f%%\n',ppm,100*run_ber(xr));
end
for dbc=[-10 0 6]
  a=10^(dbc/20)*rms(abs(x0));
  fprintf('+ CW spur @60kHz %+d dBc       : %.2f%%\n',dbc,100*run_ber(x0+a*exp(1j*2*pi*60e3/fs*n)));
end

function b=run_ber(x)
  x=x/max(abs([real(x);imag(x)]))*26000; o=zeros(2*numel(x),1); o(1:2:end)=real(x); o(2:2:end)=imag(x);
  f=fopen('/tmp/rep.iq','w'); fwrite(f,int16(round(o)),'int16'); fclose(f);
  r=soak_decode_k5('/tmp/rep.iq','label','r'); b=r.codedBER;
end
