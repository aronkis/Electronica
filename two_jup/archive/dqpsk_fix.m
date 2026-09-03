refpay=load('/mnt/onetb/scratch/qpsk_variants/k5_240/ref_paysym.txt'); g=refpay(:,1)+1j*refpay(:,2); Ns=numel(g);
rng(5); bits=pskdemod(g,4,pi/4,'gray');
fprintf('\n=== DQPSK vs coherent under reproduced phase random-walk (both + AWGN 13dB) ===\n');
for stepdeg=[8 16 24 40]
  ph=cumsum(stepdeg*pi/180*randn(Ns,1)); rx=awgn(g.*exp(1j*ph),13,'measured');
  % COHERENT: best of 4 constant rotations
  bc=Inf; for rr=[0 90 180 270], bc=min(bc,mean(pskdemod(rx*exp(-1j*deg2rad(rr)),4,pi/4,'gray')~=bits)); end
  % DIFFERENTIAL: symbols at {0,90,180,270} -> demod with phase 0
  dg=g(2:end).*conj(g(1:end-1)); drx=rx(2:end).*conj(rx(1:end-1));
  bg=pskdemod(dg,4,0,'gray'); brx=pskdemod(drx,4,0,'gray');
  bd=Inf; for rr=[0 90 180 270], bd=min(bd,mean(pskdemod(drx*exp(-1j*deg2rad(rr)),4,0,'gray')~=bg)); end
  fprintf('phase-walk %2d deg/sym:  COHERENT SER=%.3f   DQPSK SER=%.3f\n',stepdeg,bc,bd);
end
% control: pure AWGN, no walk -> both should be low
rx=awgn(g,13,'measured'); bc=min(arrayfun(@(rr) mean(pskdemod(rx*exp(-1j*deg2rad(rr)),4,pi/4,'gray')~=bits),[0 90 180 270]));
fprintf('(no walk, AWGN only):   COHERENT SER=%.3f\n',bc);
