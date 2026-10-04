/* Bounded dual-scene crossfade. Smooth equal-power gains; rhythmic handover
   around the middle prevents two prominent, unrelated drum patterns fighting.
   No claim of automatic DJ beatmatching or universal loudness equality. MIT. */
#include "SceneMixer.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#define BLOCK 128
#define PI 3.14159265358979323846
typedef struct Scene {OndeDSP *core;double seconds;} Scene;
struct OndeSceneMixer {
 double rate;Scene *active,*next;
 _Atomic(Scene*) pending;_Atomic(Scene*) retired;_Atomic(Scene*) visible;
 _Atomic float targetGain,progress,peak,rms,actualGain;_Atomic int state;
 uint64_t wait,at,length;float master;
 OndePlaybackEnvelope entrance;
 _Atomic int transportTarget;
 _Atomic float transportSeconds,entranceGain,entranceProgress;
 _Atomic uint64_t transportSerial;
 uint64_t appliedTransportSerial;
 uint64_t entranceFrames,entranceIntermediate;float entranceFirst;
 _Atomic uint64_t publishedEntranceSerial,publishedEntranceFrames,publishedEntranceIntermediate;
 _Atomic float publishedEntranceFirst;
 float al[BLOCK],ar[BLOCK],bl[BLOCK],br[BLOCK];
};
static float smooth(float x){if(x<0)x=0;if(x>1)x=1;return x*x*(3-2*x);}
static void dispose(Scene*s){if(s){onde_dsp_destroy(s->core);free(s);}}
OndeSceneMixer*onde_scene_mixer_create(double rate){
 if(!isfinite(rate)||rate<8000||rate>96000)return NULL;
 OndeSceneMixer*m=calloc(1,sizeof(*m));if(!m)return NULL;m->rate=rate;
 atomic_init(&m->pending,NULL);atomic_init(&m->retired,NULL);atomic_init(&m->visible,NULL);
 atomic_init(&m->transportTarget,1);atomic_init(&m->transportSeconds,0);
 atomic_init(&m->entranceGain,0);atomic_init(&m->entranceProgress,0);
 atomic_init(&m->transportSerial,0);m->appliedTransportSerial=UINT64_MAX;
 atomic_init(&m->publishedEntranceSerial,UINT64_MAX);
 atomic_init(&m->publishedEntranceFrames,0);atomic_init(&m->publishedEntranceIntermediate,0);atomic_init(&m->publishedEntranceFirst,0);
 onde_envelope_reset(&m->entrance,0);
 atomic_init(&m->targetGain,0);atomic_init(&m->actualGain,0);atomic_init(&m->progress,1);atomic_init(&m->peak,0);atomic_init(&m->rms,0);atomic_init(&m->state,0);
 if(!atomic_is_lock_free(&m->pending)||!atomic_is_lock_free(&m->targetGain)){free(m);return NULL;}return m;
}
void onde_scene_mixer_collect(OndeSceneMixer*m){if(m)dispose(atomic_exchange_explicit(&m->retired,NULL,memory_order_acq_rel));}
void onde_scene_mixer_destroy(OndeSceneMixer*m){
 if(!m)return;dispose(m->active);dispose(m->next);dispose(atomic_load(&m->pending));dispose(atomic_load(&m->retired));free(m);
}
int onde_scene_mixer_submit(OndeSceneMixer*m,OndeDSP*core,double seconds){
 if(!m||!core||!isfinite(seconds)||seconds<2||seconds>30)return 0;
 Scene*s=malloc(sizeof(*s));if(!s)return 0;s->core=core;s->seconds=seconds;
 dispose(atomic_exchange_explicit(&m->pending,s,memory_order_acq_rel));return 1;
}
void onde_scene_mixer_playback(OndeSceneMixer*m,int playing,double seconds){
 if(!m||!isfinite(seconds)||seconds<0||seconds>30)return;
 atomic_store_explicit(&m->transportSeconds,(float)seconds,memory_order_relaxed);
 atomic_store_explicit(&m->transportTarget,playing!=0,memory_order_relaxed);
 atomic_fetch_add_explicit(&m->transportSerial,1,memory_order_release);
}
uint64_t onde_scene_mixer_entrance_frames(const OndeSceneMixer*m){return m?atomic_load(&m->publishedEntranceFrames):0;}
uint64_t onde_scene_mixer_entrance_intermediate(const OndeSceneMixer*m){return m?atomic_load(&m->publishedEntranceIntermediate):0;}
uint64_t onde_scene_mixer_entrance_serial(const OndeSceneMixer*m){return m?atomic_load(&m->publishedEntranceSerial):0;}
float onde_scene_mixer_entrance_first_gain(const OndeSceneMixer*m){return m?atomic_load(&m->publishedEntranceFirst):0;}
int onde_scene_mixer_entrance_pending(const OndeSceneMixer*m){return m&&atomic_load(&m->transportSerial)!=atomic_load(&m->publishedEntranceSerial);}
float onde_scene_mixer_entrance_gain(const OndeSceneMixer*m){return m?atomic_load(&m->entranceGain):0;}
float onde_scene_mixer_entrance_progress(const OndeSceneMixer*m){return m?atomic_load(&m->entranceProgress):0;}
void onde_scene_mixer_gain(OndeSceneMixer*m,float gain){if(m&&isfinite(gain))atomic_store(&m->targetGain,fmaxf(0,fminf(1,gain)));}
OndeDSP*onde_scene_mixer_visible(const OndeSceneMixer*m){Scene*s=m?atomic_load_explicit(&m->visible,memory_order_acquire):NULL;return s?s->core:NULL;}
int onde_scene_mixer_state(const OndeSceneMixer*m){return m?atomic_load(&m->state):0;}
int onde_scene_mixer_pending(const OndeSceneMixer*m){return m&&atomic_load(&m->pending)!=NULL;}
float onde_scene_mixer_progress(const OndeSceneMixer*m){return m?atomic_load(&m->progress):1;}
float onde_scene_mixer_actual_gain(const OndeSceneMixer*m){return m?atomic_load(&m->actualGain):0;}
float onde_scene_mixer_peak(const OndeSceneMixer*m){return m?atomic_load(&m->peak):0;}
float onde_scene_mixer_rms(const OndeSceneMixer*m){return m?atomic_load(&m->rms):0;}
void onde_scene_mixer_render(OndeSceneMixer*m,float*l,float*r,uint32_t frames){
 if(!m||!l||!r)return;uint32_t written=0;float peak=0;double energy=0;
 const float up=1-expf(-1.f/(.65f*m->rate)),down=1-expf(-1.f/(.085f*m->rate));
 while(written<frames){
  uint64_t serial=atomic_load_explicit(&m->transportSerial,memory_order_acquire);
  if(serial!=m->appliedTransportSerial){
   onde_envelope_to(&m->entrance,atomic_load(&m->transportTarget)?1.f:0.f,atomic_load(&m->transportSeconds));
   m->appliedTransportSerial=serial;m->entranceFrames=0;m->entranceIntermediate=0;m->entranceFirst=0;
  }
  if(!m->next&&!atomic_load_explicit(&m->retired,memory_order_acquire)){
   Scene*p=atomic_exchange_explicit(&m->pending,NULL,memory_order_acq_rel);
   if(p){
    if(!m->active){m->active=p;atomic_store_explicit(&m->visible,p,memory_order_release);}
    else {m->next=p;m->at=0;m->length=(uint64_t)(p->seconds*m->rate);m->wait=onde_dsp_frames_to_bar(m->active->core);atomic_store(&m->progress,0);atomic_store(&m->state,1);}
   }
  }
  uint32_t n=frames-written;if(n>BLOCK)n=BLOCK;
  int fading=m->next&&m->wait==0;
  if(m->next&&m->wait>0&&n>m->wait)n=(uint32_t)m->wait;
  if(fading&&n>m->length-m->at)n=(uint32_t)(m->length-m->at);
  if(fading){
   atomic_store(&m->state,2);atomic_store_explicit(&m->visible,m->next,memory_order_release);
   float x=(float)m->at/(float)m->length;
   onde_dsp_set_rhythm_weight(m->active->core,1-smooth(x/.58f));
   onde_dsp_set_rhythm_weight(m->next->core,smooth((x-.42f)/.58f));
  }
  if(m->active)onde_dsp_render(m->active->core,m->al,m->ar,n);
  if(fading)onde_dsp_render(m->next->core,m->bl,m->br,n);
  float target=atomic_load(&m->targetGain);
  for(uint32_t i=0;i<n;i++){
   float a=m->active?m->al[i]:0,b=m->active?m->ar[i]:0;
   if(fading){float x=smooth((float)(m->at+i)/(float)m->length);float old=cosf(x*(float)PI*.5f),fresh=sinf(x*(float)PI*.5f);a=a*old+m->bl[i]*fresh;b=b*old+m->br[i]*fresh;}
   m->master+=(target>m->master?up:down)*(target-m->master);a*=m->master*m->entrance.value;b*=m->master*m->entrance.value;
   /* Persistent render-clock audit: UI/CLI polling can miss a short entrance. */
   if(m->active&&m->entrance.target>0){
    if(m->entranceFrames==0)m->entranceFirst=m->entrance.value;
    m->entranceFrames++;
    if(m->entrance.value>0&&m->entrance.value<1)m->entranceIntermediate++;
   }
   /* Never consume a fade while an asynchronous scene is still loading. */
   if(m->active || m->entrance.target==0)onde_envelope_step(&m->entrance,1./m->rate);
   /* Normally inactive guard, not a gain strategy. */
   if(fabsf(a)>.88f)a=copysignf(.88f+.07f*tanhf((fabsf(a)-.88f)/.07f),a);
   if(fabsf(b)>.88f)b=copysignf(.88f+.07f*tanhf((fabsf(b)-.88f)/.07f),b);
   l[written+i]=a;r[written+i]=b;peak=fmaxf(peak,fmaxf(fabsf(a),fabsf(b)));energy+=(double)a*a+(double)b*b;
  }
  if(m->next&&m->wait>0)m->wait-=n;
  if(fading){m->at+=n;atomic_store(&m->progress,(float)m->at/(float)m->length);
   if(m->at>=m->length){Scene*old=m->active;m->active=m->next;m->next=NULL;onde_dsp_set_rhythm_weight(m->active->core,1);atomic_store_explicit(&m->retired,old,memory_order_release);atomic_store(&m->state,0);}
  }
  written+=n;
 }
 atomic_store(&m->publishedEntranceSerial,m->appliedTransportSerial);
 atomic_store(&m->publishedEntranceFrames,m->entranceFrames);atomic_store(&m->publishedEntranceIntermediate,m->entranceIntermediate);atomic_store(&m->publishedEntranceFirst,m->entranceFirst);
 atomic_store(&m->entranceGain,m->entrance.value);atomic_store(&m->entranceProgress,onde_envelope_progress(&m->entrance));
 atomic_store(&m->actualGain,m->master*m->entrance.value);atomic_store(&m->peak,peak);atomic_store(&m->rms,frames?sqrtf(energy/(2.*frames)):0);
}
