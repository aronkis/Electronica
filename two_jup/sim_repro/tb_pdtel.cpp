#include "VPdTelemetry.h"
#include "verilated.h"
#include <cstdio>
int main(int argc,char**argv){ Verilated::commandArgs(argc,argv); VPdTelemetry* t=new VPdTelemetry; FILE* f=fopen(argv[1],"wb");
  auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); };
  t->reset=1; t->enb_1_2_0=1; t->validIn=0; t->dI=0; t->dQ=0; t->thrEx=0; t->tRef=0; t->tOff=0; t->done=0; t->newPk=0; t->succ=0; t->sync=0; t->armed=0;
  t->taRef=0; t->accOff=0; t->fifoEnt=0; t->vPop=0; t->tRefLong=0; t->runMax=0; t->heldTs=0; tick(); tick(); t->reset=0;
  // 60 symbols, one valid every 4 enb cycles (sps 4); known fields per symbol k
  for(int k=0;k<60;k++){ for(int c=0;c<4;c++){ bool v=(c==0);
      t->validIn=v; t->tRef=(1000+k)&2047; t->tOff=(k<30)?77:109; t->done=(k%10==0); t->newPk=(k%7==0); t->succ=1; t->thrEx=(k%3==0); t->sync=(k==5); t->armed=1;
      t->dI=100*k-3000; t->dQ=-(50*k); t->taRef=(500+k)&2047; t->accOff=(k*13)&2047; t->fifoEnt=(k==40)?12334:12333; t->vPop=(k==40)?0:1;
      t->tRefLong=100000+k; t->runMax=0x1234+k; t->heldTs=0xBEEF0000u+k;
      tick(); short I=(short)t->telI, Q=(short)t->telQ; fwrite(&I,2,1,f); fwrite(&Q,2,1,f); } }
  // an idle stretch (no valid) so slots 4..6 appear
  t->validIn=0; for(int c=0;c<12;c++){ tick(); short I=(short)t->telI, Q=(short)t->telQ; fwrite(&I,2,1,f); fwrite(&Q,2,1,f); }
  fclose(f); printf("TB_PDTEL_DONE\n"); delete t; return 0; }
