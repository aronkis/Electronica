/* txplane_score.c -- port of rx_seam_checker.v semantics over a _rxw.txt capture (hex,last,user).
 * frame = user-marked word + 190 words. magic 'Q','K', len<=1516, CRC32 (zlib) over 0..12+len-1 with
 * the CRC field zeroed. Options: --dewhiten (apply qpsk_whiten before parsing, as decode() does),
 * --tgen (CRC constant 0x54474E21 counts as ok). Prints counts + per-bad-frame lines (index, class, seq).
 * build: gcc -O2 -I../../host -o txplane_score txplane_score.c ../../host/qpsk_frame.c ../../host/qpsk_seq.c */
#include "qpsk_frame.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
int main(int argc, char **argv){
  int dew=0, tgen=0, skip=0, nf=0, started=0, skipgood=0, verbose=0; long scored=0, goodseen=0; const char *fn=NULL;
  for(int i=1;i<argc;i++){ if(!strcmp(argv[i],"--dewhiten")) dew=1; else if(!strcmp(argv[i],"--tgen")) tgen=1; else if(!strncmp(argv[i],"--skip=",7)) skip=atoi(argv[i]+7); else if(!strncmp(argv[i],"--nf=",5)) nf=atoi(argv[i]+5); else if(!strncmp(argv[i],"--skipgood=",11)) skipgood=atoi(argv[i]+11); else if(!strcmp(argv[i],"-v")) verbose=1; else fn=argv[i]; }
  FILE *f=fopen(fn,"r"); if(!f){ fprintf(stderr,"no %s\n",fn); return 2; }
  unsigned char fr[1528]; int widx=-1; long frames=0, ok=0, fail=0, bad=0, shortf=0, orphan=0, seqmax=0; char ln[128];
  long fidx=-1; long badlist_n=0;
  while(fgets(ln,sizeof ln,f)){
    unsigned long long v; int last,user; if(sscanf(ln,"%llx,%d,%d",&v,&last,&user)!=3) continue;
    if(user){ if(widx>=0 && widx!=191) shortf++; frames++; fidx++; widx=0; }
    else if(widx<0 || widx>=191){ orphan++; continue; }
    for(int b=0;b<8;b++) fr[widx*8+b]=(v>>(8*b))&255; widx++;
    if(widx==191){
      if(fidx<skip) continue;
      unsigned char c[1528]; memcpy(c,fr,1528); if(dew) qpsk_whiten(c,1528);
      int len=c[2]|(c[3]<<8); uint32_t seq=c[4]|(c[5]<<8)|(c[6]<<16)|((uint32_t)c[7]<<24);
      if(!started){ if(c[0]==0x51&&c[1]==0x4B&&len<=1516) started=1; else continue; }
      if(goodseen<skipgood){ if(c[0]==0x51&&c[1]==0x4B&&len<=1516) goodseen++; continue; }
      if(nf>0 && scored>=nf) continue; scored++;
      if(verbose) printf("F %ld seq=%u %02x%02x len=%d\n",fidx,seq,c[0],c[1],len);
      if(c[0]!=0x51||c[1]!=0x4B||len>1516){ bad++; printf("BAD %ld magic seq=%u b0..3=%02x%02x%02x%02x\n",fidx,seq,c[0],c[1],c[2],c[3]); badlist_n++; }
      else { uint32_t cf=c[8]|(c[9]<<8)|(c[10]<<16)|((uint32_t)c[11]<<24); unsigned char z[1528]; memcpy(z,c,1528); memset(z+8,0,4);
        uint32_t crc=qpsk_crc32(z,(size_t)(12+len));
        if(crc==cf || (tgen && cf==0x54474E21u)) { ok++; if((long)seq>seqmax) seqmax=seq; }
        else { fail++; printf("BAD %ld crc seq=%u len=%d\n",fidx,seq,len); } }
    }
  }
  printf("SCORE skip=%d scored=%ld frames=%ld crc_ok=%ld crc_fail=%ld magic_bad=%ld short=%ld orphan=%ld seqmax=%ld  magic_bad%%=%.3f crc_fail%%=%.3f\n",
    skip,scored,frames,ok,fail,bad,shortf,orphan,seqmax, frames?100.0*bad/frames:0, frames?100.0*fail/frames:0);
  return 0;
}
