/* Original additive source/filter vowel ensemble. Code MIT; renders CC0.
   All frequency values describe timbre, not cognitive entrainment. */
#include "VowelChoir.h"
#include <stdlib.h>
#include <math.h>
#include <string.h>
#define N 2048
#define LO 48
#define HI 76
#define VOICES 24
#define TAU 6.2831853071795864769
#define VOWELS 3
struct Singer {double phase,step,lfo;float gain,target,panL,panR,coefficient;int note,active;};
struct VowelChoir {double sr;float table[HI-LO+1][VOWELS][N+1];struct Singer singer[VOICES];int chord[4];float vowel,dcL,dcR,prevL,prevR;};
static double frequency(int n){return 440*pow(2,(n-69)/12.0);}
static float look(const float *t,double p){double x=p*N;int i=(int)x;float f=x-i;return t[i]+f*(t[i+1]-t[i]);}
VowelChoir *choir_create(double sr){
 if(!isfinite(sr)||sr<8000||sr>96000)return NULL;
 VowelChoir*c=calloc(1,sizeof(*c));if(!c)return NULL;c->sr=sr;
 for(int j=0;j<4;j++)c->chord[j]=-1;
 /* Ah / Oh / Oo. Broad formants, spectral tilt, no broadband hiss. */
 const double formant[3][4]={{720,1120,2440,3180},{440,820,2380,3040},{330,690,2220,2930}};
 const double width[4]={120,160,230,330},weight[4]={1,.82,.22,.09};
 for(int n=LO;n<=HI;n++)for(int v=0;v<3;v++){
  double f=frequency(n),energy=0;float *table=c->table[n-LO][v];
  for(int h=1;h<=48 && f*h<fmin(sr*.40,5500);h++){
   double response=.075;
   for(int k=0;k<4;k++){double z=(f*h-formant[v][k])/width[k];response+=weight[k]*exp(-.5*z*z);}
   double amplitude=response/pow(h,.80),phase=-.11*h*h;
   for(int i=0;i<N;i++)table[i]+=(float)(amplitude*sin(TAU*h*i/N+phase));
  }
  for(int i=0;i<N;i++)energy+=table[i]*table[i];
  float scale=.28f/(float)sqrt(fmax(energy/N,1e-12));
  for(int i=0;i<N;i++)table[i]*=scale;
  table[N]=table[0];
 }
 return c;
}
void choir_destroy(VowelChoir*c){free(c);}
void choir_chord(VowelChoir*c,const int midi[4],double transition){
 if(!c)return;float coefficient=1-exp(-1/(fmax(.20,transition)*c->sr));
 /* Common tones continue untouched; only changed inner voices crossfade. */
 for(int i=0;i<VOICES;i++)if(c->singer[i].active){
  int keep=0;for(int j=0;j<4;j++)if(midi[j]==c->singer[i].note)keep=1;
  if(!keep){c->singer[i].target=0;c->singer[i].coefficient=coefficient;}
 }
 const double cents[3]={-4.1,0.7,3.7};
 for(int j=0;j<4;j++){
  if(midi[j]<LO||midi[j]>HI)continue;
  int exists=0;for(int i=0;i<VOICES;i++)if(c->singer[i].active && c->singer[i].target>0 && c->singer[i].note==midi[j])exists=1;
  if(exists)continue;
  for(int u=0;u<3;u++){
   struct Singer*s=NULL;for(int i=0;i<VOICES;i++)if(!c->singer[i].active){s=&c->singer[i];break;}
   if(!s)break;memset(s,0,sizeof(*s));s->active=1;s->note=midi[j];
   s->step=frequency(midi[j])*pow(2,cents[u]/1200)/c->sr;
   s->phase=fmod(.183*j+.293*u+.17,1);s->lfo=fmod(.29*j+.13*u,1);
   s->target=(j<2?.115f:.088f);s->coefficient=coefficient;
   float pan=.18f+.16f*j+(u-1)*.055f;s->panL=sqrtf(1-pan);s->panR=sqrtf(pan);
  }
  c->chord[j]=midi[j];
 }
}
void choir_frame(VowelChoir*c,float vowel,float*l,float*r){
 *l=*r=0;if(!c)return;
 if(!isfinite(vowel))vowel=0;vowel=fmaxf(0,fminf(2,vowel));c->vowel+=.000015f*(vowel-c->vowel);
 int a=(int)c->vowel,b=a<2?a+1:a;float mix=c->vowel-a;
 for(int i=0;i<VOICES;i++){
  struct Singer*s=&c->singer[i];if(!s->active)continue;
  s->gain+=s->coefficient*(s->target-s->gain);
  if(s->target==0&&s->gain<.000005f){s->active=0;continue;}
  float x=look(c->table[s->note-LO][a],s->phase)*(1-mix)+look(c->table[s->note-LO][b],s->phase)*mix;
  double shimmer=sin(TAU*s->lfo);s->lfo+=.087/c->sr;if(s->lfo>=1)s->lfo-=1;
  /* Very slow, small movement: no tremolo, no vibrato mapped to EEG bands. */
  s->phase+=s->step*(1+.00012*shimmer);if(s->phase>=1)s->phase-=floor(s->phase);
  x*=s->gain*(.985f+.015f*shimmer);*l+=x*s->panL;*r+=x*s->panR;
 }
}
int choir_voices(const VowelChoir*c){int n=0;if(c)for(int i=0;i<VOICES;i++)n+=c->singer[i].active;return n;}
