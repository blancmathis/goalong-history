/* Acoustic note sampler for Onde. Original code MIT; sample bank VSCO 2 CE CC0.
   Allocation and loading ONLY before rendering. No disk, locks, or allocations
   in note scheduling or render. Each sample owns one immutable stereo buffer. */
#include "Orchestra.h"
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <stdatomic.h>
#define MAX_SAMPLES 112
#define MAX_VOICES 64
#define MAX_TOTAL_FRAMES 24000000u
#define PI 3.14159265358979323846

struct OndeSampleBuffer { _Atomic uint32_t references; float *l,*r; uint32_t n; double rate; };
typedef struct {const float *l,*r;const int16_t *pcm16;uint32_t n;double rate;int instrument,root,rr;OndeSampleBuffer *buffer;} Sample;
typedef struct {const Sample *sample;double at,step;uint64_t age,life;float attack,release,gain,panL,panR,lpL,lpR;int active,group,held;double loopStart,loopEnd,loopFade;} Voice;
struct Orchestra {double sr;float lastWarmth,coefficient;Sample samples[MAX_SAMPLES];Voice voices[MAX_VOICES];int count,families;uint64_t events;uint32_t totalFrames;uint64_t rr[12][128];};
static float clip(float x,float lo,float hi){return x<lo?lo:x>hi?hi:x;}
static float smooth(float x){x=clip(x,0,1);return x*x*(3-2*x);}
Orchestra *orc_create(double sr){if(!isfinite(sr)||sr<8000||sr>96000)return NULL;Orchestra *o=calloc(1,sizeof(*o));if(o){o->sr=sr;o->lastWarmth=NAN;}return o;}
/* Immutable PCM is validated once and retained by each scene. Reference counts
   change only during preparation/disposal, never in the real-time callback. */
OndeSampleBuffer *onde_sample_buffer_create(const float *l,const float *r,uint32_t n,double rate){
 if(!l||n<64||n>1500000||!isfinite(rate)||rate<8000||rate>96000)return NULL;
 for(uint32_t i=0;i<n;i++)if(!isfinite(l[i])||fabsf(l[i])>1.01f||(r&&(!isfinite(r[i])||fabsf(r[i])>1.01f)))return NULL;
 OndeSampleBuffer *b=calloc(1,sizeof(*b));if(!b)return NULL;
 b->l=malloc(n*sizeof(float));b->r=malloc(n*sizeof(float));
 if(!b->l||!b->r){free(b->l);free(b->r);free(b);return NULL;}
 memcpy(b->l,l,n*sizeof(float));memcpy(b->r,r?r:l,n*sizeof(float));
 b->n=n;b->rate=rate;atomic_init(&b->references,1);return b;
}
void onde_sample_buffer_release(OndeSampleBuffer *b){
 if(b&&atomic_fetch_sub_explicit(&b->references,1,memory_order_acq_rel)==1){free(b->l);free(b->r);free(b);}
}
uint32_t onde_sample_buffer_references(const OndeSampleBuffer *b){return b?atomic_load_explicit(&b->references,memory_order_relaxed):0;}
void orc_destroy(Orchestra *o){if(!o)return;for(int i=0;i<o->count;i++)onde_sample_buffer_release(o->samples[i].buffer);free(o);}
int orc_add_shared(Orchestra *o,int inst,int root,int rr,OndeSampleBuffer *b){
 if(!o||!b||inst<0||inst>11||root<0||root>127||rr<0||rr>7||o->count>=MAX_SAMPLES||o->totalFrames+b->n>MAX_TOTAL_FRAMES)return 0;
 for(int j=0;j<o->count;j++)if(o->samples[j].instrument==inst&&o->samples[j].root==root&&o->samples[j].rr==rr)return 0;
 atomic_fetch_add_explicit(&b->references,1,memory_order_relaxed);
 Sample *s=&o->samples[o->count++];s->l=b->l;s->r=b->r;s->n=b->n;s->rate=b->rate;s->root=root;s->rr=rr;s->instrument=inst;s->buffer=b;
 o->totalFrames+=b->n;o->families|=(1<<inst);return 1;
}
int orc_add(Orchestra *o,int inst,int root,int rr,const float *l,const float *r,uint32_t n,double rate){
 if(!o)return 0;
 OndeSampleBuffer *b=onde_sample_buffer_create(l,r,n,rate);if(!b)return 0;
 int result=orc_add_shared(o,inst,root,rr,b);onde_sample_buffer_release(b);return result;
}
/* Goalong: borrowed, read-only mapped stereo PCM16. Caller retains the mapping
   until the DSP is destroyed. Descriptor lives inline; render never allocates. */
int orc_add_pcm16(Orchestra *o,int inst,int root,int rr,const int16_t *pcm,uint32_t n,double rate){
 if(!o||!pcm||n<64||n>1500000||!isfinite(rate)||rate<8000||rate>96000||
    inst<0||inst>11||root<0||root>127||rr<0||rr>7||o->count>=MAX_SAMPLES||o->totalFrames+n>MAX_TOTAL_FRAMES)return 0;
 for(int j=0;j<o->count;j++)if(o->samples[j].instrument==inst&&o->samples[j].root==root&&o->samples[j].rr==rr)return 0;
 Sample *s=&o->samples[o->count++];s->pcm16=pcm;s->n=n;s->rate=rate;s->root=root;s->rr=rr;s->instrument=inst;
 o->totalFrames+=n;o->families|=(1<<inst);return 1;
}
int orc_count(const Orchestra *o){return o?o->count:0;}
int orc_families(const Orchestra *o){return o?o->families:0;}
int orc_voices(const Orchestra *o){int n=0;if(o)for(int i=0;i<MAX_VOICES;i++)n+=o->voices[i].active;return n;}
uint64_t orc_events(const Orchestra *o){return o?o->events:0;}
static int make_note(Orchestra *o,int inst,int midi,float velocity,float pan,double seconds,uint64_t seed,int held,double fade){
 if(!o||inst<0||inst>11||midi<0||midi>127||velocity<=.00001f||!isfinite(velocity)||!isfinite(seconds)||seconds<=0)return 0;
 int root=-1,distance=129;for(int i=0;i<o->count;i++){const Sample *s=&o->samples[i];if(s->instrument==inst&&abs(s->root-midi)<distance){root=s->root;distance=abs(root-midi);}}
 if(root<0||distance>12)return 0;
 const Sample *choices[8];int count=0;
 for(int i=0;i<o->count&&count<8;i++)if(o->samples[i].instrument==inst&&o->samples[i].root==root)choices[count++]=&o->samples[i];
 uint64_t position=o->rr[inst][root]++;const Sample *sample=choices[(position+seed)%count];
 Voice *v=NULL;for(int i=0;i<MAX_VOICES;i++)if(!o->voices[i].active){v=&o->voices[i];break;}if(!v)return 0;
 memset(v,0,sizeof(*v));v->sample=sample;v->step=pow(2.,(midi-root)/12.)*sample->rate/o->sr;
 double maximum=(sample->n-4)/v->step;v->life=(uint64_t)fmin(seconds*o->sr,maximum);if(v->life<32)return 0;
 int sustain=inst<3||inst==5||inst==6||inst==7;
 if(held && sustain && sample->n>sample->rate*1.2){v->held=1;v->life=(uint64_t)(seconds*o->sr);v->loopStart=sample->n*.26;v->loopEnd=sample->n*.80;v->loopFade=fmin(sample->rate*.23,(v->loopEnd-v->loopStart)*.20);}
 v->attack=(v->held?1.2:sustain?.46:inst==8?.010:inst==9?.012:.007)*o->sr;
 v->release=(v->held?1.6:sustain?.95:inst==8?.30:inst==9?.30:.065)*o->sr;
 if(fade>0){v->attack=fade*o->sr;v->release=fade*o->sr;}
 v->attack=fminf(v->attack,v->life*.25f);v->release=fminf(v->release,v->life*.35f);
 static const float variations[4]={1,.975f,.988f,.965f};v->gain=clip(velocity,0,2)*variations[(position+seed)%4];
 pan=clip(pan,.06,.94);v->panL=sqrtf(1-pan)*1.41421356f;v->panR=sqrtf(pan)*1.41421356f;
 v->group=inst==11?6:inst<3?0:inst==3||inst==4?4:inst==5?1:inst<8?2:inst==8?3:5;
 v->active=1;o->events++;return 1;
}
int orc_note(Orchestra *o,int inst,int midi,float velocity,float pan,double seconds,uint64_t seed){return make_note(o,inst,midi,velocity,pan,seconds,seed,0,0);}
int orc_note_held(Orchestra *o,int inst,int midi,float velocity,float pan,double seconds,uint64_t seed){return make_note(o,inst,midi,velocity,pan,seconds,seed,1,0);}
int orc_note_legato(Orchestra *o,int inst,int midi,float velocity,float pan,double seconds,double fade,uint64_t seed){if(!isfinite(fade)||fade<.02||fade>30)return 0;return make_note(o,inst,midi,velocity,pan,seconds,seed,1,fade);}
static float cubic(const float *p,uint32_t n,double pos){
 int i=(int)pos;float t=(float)(pos-i);float a=p[i>0?i-1:0],b=p[i],c=p[i+1<(int)n?i+1:n-1],d=p[i+2<(int)n?i+2:n-1];
 return b+.5f*t*(c-a+t*(2*a-5*b+4*c-d+t*(3*(b-c)+d-a)));
}
static float cubic_sample(const Sample *s,int channel,double pos){
 if(!s->pcm16)return cubic(channel?s->r:s->l,s->n,pos);
 int i=(int)pos;float t=(float)(pos-i);
 float a=s->pcm16[2*(i>0?i-1:0)+channel]/32768.f,b=s->pcm16[2*i+channel]/32768.f;
 float c=s->pcm16[2*(i+1<(int)s->n?i+1:s->n-1)+channel]/32768.f;
 float d=s->pcm16[2*(i+2<(int)s->n?i+2:s->n-1)+channel]/32768.f;
 return b+.5f*t*(c-a+t*(2*a-5*b+4*c-d+t*(3*(b-c)+d-a)));
}
void orc_frame(Orchestra *o,const float levels[7],float warmth,float *l,float *r){
 *l=0;*r=0;if(!o||o->count==0)return;
 /* A gentle, fixed-band smoothing filter preserves real instrument attacks. */
 if(warmth!=o->lastWarmth){o->lastWarmth=warmth;o->coefficient=1-expf(-2*PI*(5100-2200*clip(warmth,0,1))/o->sr);}
 float coef=o->coefficient;
 for(int i=0;i<MAX_VOICES;i++){
  Voice *v=&o->voices[i];if(!v->active)continue;
  if(v->age>=v->life||v->at>=v->sample->n-3){v->active=0;continue;}
  float x=cubic_sample(v->sample,0,v->at),y=cubic_sample(v->sample,1,v->at);
  if(v->held && v->at>=v->loopEnd-v->loopFade){
   double offset=v->at-(v->loopEnd-v->loopFade);float blend=smooth(offset/v->loopFade);
   x=x*(1-blend)+cubic_sample(v->sample,0,v->loopStart+offset)*blend;
   y=y*(1-blend)+cubic_sample(v->sample,1,v->loopStart+offset)*blend;
  }
  v->lpL+=coef*(x-v->lpL);v->lpR+=coef*(y-v->lpR);
  float envelope=smooth(v->age/fmaxf(1,v->attack))*smooth((v->life-v->age)/fmaxf(1,v->release));
  float gain=envelope*v->gain*levels[v->group];float mid=(v->lpL+v->lpR)*.5f,side=(v->lpL-v->lpR)*.32f;
  *l+=(mid+side)*gain*v->panL;*r+=(mid-side)*gain*v->panR;
  v->age++;v->at+=v->step;
  if(v->held && v->at>=v->loopEnd)v->at=v->loopStart+v->loopFade+(v->at-v->loopEnd);
 }
}
