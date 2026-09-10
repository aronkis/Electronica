// sim_ring.cpp -- [sim] task 6: per-beat dump around Rate_Handle EMPTY-edge events.
// usage: sim_ring <iq> <nsamp> <rstcs_end> <prefix> [cad] [vph] [win]
// Ring-buffers the last <win> enb beats; on each pop_on_empty (and for <win>
// beats after) writes them out.  One line per enb beat.
#include "Vwrap_ring.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
static const long FRSAMP=49332;
struct Row { long sidx; long beat; int inI,inQ,strobe,vin,pop,vout,outI,outQ;
             int pp,qp,vpush,vpop,occ,pe,pf,cI,cQ,cV,tref;
             int creg,cnt,dlt,mu,und; long ted; };
int main(int argc,char** argv){
    Verilated::commandArgs(argc,argv);
    if(argc<5){ fprintf(stderr,"usage: sim_ring iq nsamp rstcs_end prefix [cad] [vph] [win]\n"); return 2; }
    const char* iqf=argv[1]; long nsamp=atol(argv[2]); long rstcs_end=atol(argv[3]);
    const char* pfx=argv[4]; int cad=(argc>5)?atoi(argv[5]):2; int vph=(argc>6)?atoi(argv[6]):0;
    int WIN=(argc>7)?atoi(argv[7]):64;
    FILE* fi=fopen(iqf,"rb"); if(!fi){ fprintf(stderr,"cannot open %s\n",iqf); return 2; }
    std::vector<short> iq(2*nsamp); long got=fread(iq.data(),2,2*nsamp,fi); fclose(fi);
    if(got/2<nsamp) nsamp=got/2;
    char fn[512]; snprintf(fn,sizeof fn,"%s_ring.txt",pfx);
    FILE* fo=fopen(fn,"w"); if(!fo) return 2;
    fprintf(fo,"# sidx,beat,inI,inQ,strobe,vin,pop,vout,outI,outQ,pushPtr,popPtr,"
               "vpush,vpop,occ,popEmpty,pushFull,corrI,corrQ,corrV,tref,"
               "countReg,counter,Delta,mu,Und,tedE\n");
    Vwrap_ring* t=new Vwrap_ring;
    long clk=0,sidx=0,beat=0; int ph=0;
    t->reset=1; t->adc_validIn=0; t->adc_dataInI=0; t->adc_dataInQ=0;
    t->rstCS=0; t->rx_input_select=1; t->skip_count=0; t->tx_data_source=0;
    t->byte_valid=0; t->byte_first=0; t->byte_data=0; t->byte_rx_ready=1;
    auto tick=[&](){ t->clk=0; t->eval(); t->clk=1; t->eval(); clk++; };
    for(int i=0;i<100;i++) tick();
    t->reset=0;
    std::vector<Row> ringbuf(WIN>0?WIN:1); long nbuf=0; long emit=0; int nev=0;
    long total=100+nsamp*(long)cad+200000;
    auto put=[&](const Row& r){ fprintf(fo,"%ld,%ld,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,"
        "%d,%d,%d,%d,%d,%d,%d,%d,%d,%ld\n", r.sidx,r.beat,r.inI,r.inQ,r.strobe,r.vin,r.pop,r.vout,
        r.outI,r.outQ,r.pp,r.qp,r.vpush,r.vpop,r.occ,r.pe,r.pf,r.cI,r.cQ,r.cV,r.tref,
        r.creg,r.cnt,r.dlt,r.mu,r.und,r.ted); };
    while(clk<total){
        if(ph==vph){ if(sidx<nsamp){ t->adc_dataInI=iq[2*sidx]; t->adc_dataInQ=iq[2*sidx+1];
                t->adc_validIn=1; sidx++; } else t->adc_validIn=0; } else t->adc_validIn=0;
        ph=(ph+1)%cad; t->rstCS=(clk>400&&clk<rstcs_end)?1:0; tick();
        if(!t->railEnb) continue;
        auto sx=[&](int v,int b){ return (v & (1<<(b-1))) ? v-(1<<b) : v; };
        Row r; r.sidx=sidx; r.beat=beat++;
        r.inI=(short)t->rhInI; r.inQ=(short)t->rhInQ; r.strobe=t->rhStrobe; r.vin=t->rhValidIn;
        r.pop=t->rhPop; r.vout=t->rhValidOut; r.outI=(short)t->rhOutI; r.outQ=(short)t->rhOutQ;
        r.pp=t->pushPtr; r.qp=t->popPtr; r.vpush=t->vPush; r.vpop=t->vPop; r.occ=t->occTrue;
        r.pe=t->popEmpty; r.pf=t->pushFull; r.cI=(short)t->corrInI; r.cQ=(short)t->corrInQ;
        r.cV=t->corrInV; r.tref=t->tref;
        r.creg=sx((int)t->icCountReg,11); r.cnt=sx((int)t->icCounter,13);
        r.dlt=sx((int)t->icDelta,11); r.mu=sx((int)t->icMu,11); r.und=t->icUnd;
        r.ted=(long)t->tedE;
        // WIN<0 selects WINDOW mode: dump one row per interpolator strobe over
        // the input-sample window [-WIN, -WIN+span).  Used to catch the
        // basepoint / NCO jump at the START of an excursion, which the
        // event-triggered mode misses (pop_on_empty sits mid-excursion).
        if(WIN<0){
            long lo=-(long)WIN, hi=lo+250000;
            if(r.sidx>=lo && r.sidx<hi && (r.strobe||r.und||r.vout)) put(r);
            if(r.sidx>=hi) break;
            continue;
        }
        if(emit>0){ put(r); emit--; }
        else { ringbuf[nbuf%WIN]=r; nbuf++; }
        if(t->popEmpty && emit==0){
            nev++;
            fprintf(fo,"# EVENT %d beat=%ld sidx=%ld\n",nev,r.beat,r.sidx);
            long start = (nbuf>WIN)? nbuf-WIN : 0;
            for(long k=start;k<nbuf;k++) put(ringbuf[k%WIN]);
            put(r); emit=WIN; nbuf=0;
            if(nev>=4) break;
        }
    }
    fclose(fo); printf("RINGDUMP %s events=%d\n",pfx,nev); delete t; return 0;
}
