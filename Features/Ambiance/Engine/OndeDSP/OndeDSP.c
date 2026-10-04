/* Onde Living Engine 4 — stable pulse / clean low end — original procedural composition.
 * MIT code, original renders CC0. Locally generated music with an optional CC0 acoustic bank.
 * One render thread per instance. UI controls and meters use lock-free atomics.
 * All voices, wavetables and delay memory are allocated by create(), never render().
 */
#include "OndeDSP.h"
#include "PhrasePlanner.h"
#include "RelaxationPlanner.h"
#include "GravityPlanner.h"
#include "OrbitPlanner.h"
#include "SonarPlanner.h"
#include "Orchestra.h"
#include "VowelChoir.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#define TAU 6.2831853071795864769
#define TABLE 16384
#define MASK (TABLE-1)
#define PADS 24
#define RELAX_VOICES 20
#define NOTES 32
#define GRAINS 10
#define LINES 8
#define DELAY 32768
#define MEMORY 262144
#define ECHO 131072
#define AP_MAX 2048
/* Scores 1..7 are the Focus signatures, 8..12 the relaxation worlds, 13 Gravity, 14 Orbit, 15 Sonar. */
#define RELAXATION(score) ((score)>=8&&(score)<=12)
#define GRAVITY 13
#define ORBIT 14
#define SONAR 15
/* Bass-led scores share the Gravity state and render their own low end. */
#define BASS_LED(score) ((score)>=GRAVITY&&(score)<=SONAR)
#define GRAVITY_VOICES 10

typedef struct { uint64_t state; } Random;
static uint64_t rnd64(Random *r) {
    uint64_t z=(r->state+=UINT64_C(0x9e3779b97f4a7c15));
    z=(z^(z>>30))*UINT64_C(0xbf58476d1ce4e5b9);
    z=(z^(z>>27))*UINT64_C(0x94d049bb133111eb);
    return z^(z>>31);
}
static float uni(Random *r){return (float)(rnd64(r)>>40)*(1.f/16777216.f);}
static float noise(Random *r){return 2.f*uni(r)-1.f;}
static float cl(float x,float a,float b){return x<a?a:x>b?b:x;}
static float smooth(float x){x=cl(x,0,1);return x*x*(3-2*x);}
static double wrap(double x){return x-floor(x);}
static double hz(double midi){return 440.*pow(2.,(midi-69.)/12.);}
typedef struct {
    double p,q,t,step,detune;
    uint64_t age,life;
    float attack,release,amp,pan,color,formant,drift,driftTarget,tone;
    int active;
} Pad;
typedef struct {
    double p[6],step[6];
    float env[6],decay[6],amp[6],gain,pan,attack,noiseEnv,noiseDecay,nlp,send;
    uint64_t age,life;
    uint32_t delay;
    int active,kind;
} Note;
typedef struct {
    double read,step;
    uint64_t age,life;
    float gain,pan,lp;
    int active;
} Grain;
typedef struct {float data[AP_MAX];int at,size;} Allpass;
typedef struct { double phase,second,step; float gain,target,pan; int active,midi; } RelaxVoice;
typedef struct { double a,b,stepA,stepB; float gain,target,left,right,colour; int active,midi,slot; } GravityVoice;
typedef struct {
    GravityVoice voice[GRAVITY_VOICES];
    double low,roll,rollStep;
    float sweep,thump,pump,tremolo,sweepCoef,thumpCoef,pumpCoef,glide,slew,tailCoef;
    float lowLast,lowTail,tailEnv;
    float acidAmp,acidBand,acidFilter,acidLow;
    float rollEnv[6],rollDecay[6],rollAmp[6],rollLevel,rollLast,rollTail,rollAttack,rollRelease;
    float entrance[3];
    uint32_t age,rollAge,rollLife;
    int armed,rollOn,division;
} Gravity;
struct OndeDSP {
    RelaxVoice relaxVoice[RELAX_VOICES];
    Gravity gravity;
    Orchestra *orchestra;
    VowelChoir *choir;
    int score;uint64_t scoreStartBar,signatureEvents;
    float choirMix,bassMix;
    OndePhrasePlan plan;int planReady;float sectionMix[7];
    _Atomic uint64_t publishedPhrase,publishedChapter,publishedPlanHash;
    _Atomic int publishedVariant;
    _Atomic float rhythmTarget;float rhythmWeight;
    _Atomic int publishedComposition,publishedChoirVoices;
    _Atomic uint64_t publishedSignatureEvents;
    _Atomic uint64_t publishedOrchestraEvents;
    _Atomic int publishedOrchestraVoices;
    double sr;
    float sine[TABLE+1];
    _Atomic float target[ONDE_PARAM_COUNT];
    _Atomic int wantedMode;
    _Atomic uint64_t wantedSeed;
    _Atomic uint64_t publishedFrames,publishedEvents,publishedNotes,publishedGrains,publishedBars;
    _Atomic float publishedPeak,publishedRms,publishedGain,publishedBpm;
    _Atomic int publishedSection,publishedHarmony,publishedVoices;
    uint64_t seed,frame,sceneStart,events,noteEvents,grainEvents,bars;
    int mode,field,section,phrase,step,motif[8],motifCursor,pattern,primary,secondary;
    uint64_t nextPad,nextGrain,nextDrift;
    double nextStep,bpm;
    float now[ONDE_PARAM_COUNT],focus,meditation,sectionEnergy,energyTarget;
    float openness,opennessTarget,detail,lowpassCoef,dampingCoef;
    Random music,air;
    Pad pads[PADS];Note notes[NOTES];Grain grains[GRAINS];
    double lfo[6],lfoStep[6];
    float slow[6],drift,driftTarget,master;
    double bassPhase,bassHarm,bassStep,bassWanted;
    float bassGate,bassGateTarget;
    float airL[4],airR[4],airCoef[4],airAmp,airAmpTarget;
    float grainMemory[MEMORY];int grainWrite;
    float echoL[ECHO],echoR[ECHO],echoLP_L,echoLP_R,echoHP_L,echoHP_R;
    int echoWrite;double echoTimeL,echoTimeR;
    float delay[LINES][DELAY],damping[LINES];int writeAt;
    double delayBase[LINES],delayPhase[LINES],delayStep[LINES];
    float feedback[LINES],delayWobble[LINES];
    Allpass diffuseL[3],diffuseR[3];
    float toneL,toneR,tone2L,tone2R,dcL,dcR,dcPrevL,dcPrevR;
    double beatPhase,beatStep;
    uint64_t tickCount,beatCount,lastBeatFrame,minBeatGap,maxBeatGap;
    float bassShape,bassCoefficient,padHP_L,padHP_R;
    _Atomic uint64_t publishedBeats,publishedTicks,publishedMinGap,publishedMaxGap;
    float delayWobbleStep[LINES];
    float stablePatternLevel;
};
static float sn(const OndeDSP *s,double phase){
    double x=phase*TABLE;int i=(int)x;float f=(float)(x-i);i&=MASK;
    return s->sine[i]+f*(s->sine[i+1]-s->sine[i]);
}
static float osc(const OndeDSP *s,double *p,double step){
    float x=sn(s,*p);*p+=step;if(*p>=1)*p-=floor(*p);return x;
}
/* Original voicings in a shared F/D modal field. A stable key, not a fixed bass. */
static const int voicing[6][5]={
    {53,60,65,67,72}, {53,60,64,67,72}, {53,58,60,65,72},
    {53,60,64,69,72}, {53,60,65,69,72}, {53,60,65,67,74}
};
static const int roots[6]={29,29,29,29,29,29};
static const int routes[4][8]={
    {0,1,0,2,0,3,0,4}, {0,2,0,4,0,1,0,3},
    {0,4,0,1,0,3,0,2}, {0,3,0,2,0,4,0,1}
};
static const int contours[4][8]={
    {0,1,2,1,0,1,3,1}, {0,2,1,2,0,2,3,2},
    {0,1,0,2,0,1,0,3}, {0,2,1,0,0,2,1,3}
};
static Pad *freePad(OndeDSP *s){
    for(int i=0;i<PADS;i++)if(!s->pads[i].active)return &s->pads[i];
    return NULL; /* Never cut a sounding voice just to make space. */
}
static Note *freeNote(OndeDSP *s){
    for(int i=0;i<NOTES;i++)if(!s->notes[i].active)return &s->notes[i];
    return NULL;
}
static void pad(OndeDSP *s,int midi,float level,int preaged){
    Pad *v=freePad(s);if(!v)return;
    memset(v,0,sizeof(*v));
    v->active=1;v->p=uni(&s->music);v->q=uni(&s->music);v->t=uni(&s->music);
    v->step=hz(midi)/s->sr;v->detune=pow(2.,(.35+.75*uni(&s->music))/1200.);
    float length=(s->mode==0?19.f:31.f)+(s->mode==0?14.f:24.f)*uni(&s->music);
    v->life=(uint64_t)(length*s->sr);v->age=preaged?(uint64_t)((3+2*uni(&s->music))*s->sr):0;
    v->attack=(s->mode==0?2.8f:5.5f)*s->sr;
    v->release=(s->mode==0?8.f:13.f)*s->sr;
    v->amp=level*(.8f+.36f*uni(&s->music));v->pan=.09f+.82f*uni(&s->music);
    v->color=.2f+.8f*uni(&s->music);v->formant=.2f+.6f*uni(&s->music);
    v->driftTarget=noise(&s->music)*.00012f;s->events++;
}
static void note(OndeDSP *s,int midi,int kind,float level,float pan,float delaySeconds){
    Note *v=freeNote(s);if(!v)return;
    memset(v,0,sizeof(*v));v->active=1;v->kind=kind;v->pan=cl(pan,.05f,.95f);
    v->gain=level*(.97f+.06f*uni(&s->music));v->delay=(uint32_t)(delaySeconds*s->sr);
    double f=hz(midi);
    const float ratios[4][6]={{1,2.0001f,3.0005f,4.001f,5.002f,6.003f},
       {1,2.0001f,3.0004f,4.001f,5.002f,7.003f},
       {1,2.006f,2.756f,4.073f,5.410f,6.831f},
       {1,1.501f,2.007f,2.997f,4.101f,5.207f}};
    const float amplitudes[4][6]={{1,.30f,.11f,.065f,.032f,.017f},
       {1,.38f,.19f,.087f,.050f,.017f},
       {1,.21f,.085f,.045f,.019f,.009f},
       {1,.18f,.16f,.052f,.017f,.008f}};
    int timbre=kind<4?kind:0;float dur;
    if(kind==4){ /* softly brushed, pitched surface; no sharp white-noise click */
        dur=.24f+.13f*uni(&s->music);v->attack=.006f*s->sr;
        v->noiseEnv=1;v->noiseDecay=expf(-1.f/(.045f*s->sr));v->send=.10f;
    }else if(kind==5){
        dur=.90f;v->attack=.024f*s->sr;v->send=.025f;
    }else{
        dur=(s->mode==0?4.5f:s->mode==1?9.f:13.f)*(kind==2?1.4f:1.f);
        v->attack=(kind==3?.8f:kind==1?.038f:kind==2?.16f:.052f)*s->sr;
        if(s->mode==2)v->attack=fmaxf(v->attack,.7f*s->sr);
        v->noiseEnv=0; /* No synthetic hammer hiss or digital noise layer. */
        v->noiseDecay=expf(-1.f/(.027f*s->sr));
        v->send=kind==2?.60f:kind==3?.75f:.38f;
    }
    v->life=(uint64_t)(dur*s->sr);
    for(int j=0;j<6;j++){
        double ratio=kind==5?j+1:ratios[timbre][j];
        if(kind==6){const float rr[6]={1,2,3,4.006f,6,8};ratio=rr[j];}
        if(kind==7){const float rr[6]={1,3.98f,9.96f,13.9f,16,20};ratio=rr[j];}
        v->step[j]=f*ratio/s->sr;
        v->p[j]=0;
        v->env[j]=1;
        float decay=kind==5?.24f/(1+j):kind==4?.045f:
            (s->mode==0?.8f:s->mode==1?2.3f:3.8f)*(kind==2?1.7f:kind==1?.57f:1.f);
        if(kind==6)decay=1.25f;
        if(kind==7)decay=.48f;
        decay/=1+j*.62f;
        v->decay[j]=expf(-1.f/(decay*s->sr));
        float upper=j==0?1.f:(.18f+.68f*s->now[ONDE_BRIGHTNESS]);
        v->amp[j]=kind==5?(j==0?1.f:j==1?.17f:0):kind==4?(j==0?.10f:0):amplitudes[timbre][j]*upper;
        if(kind==6){const float aa[6]={1,.22f,.13f,.18f,.035f,.01f};v->amp[j]=aa[j]*(j==0?1.f:.4f+.6f*s->now[ONDE_BRIGHTNESS]);v->attack=.026f*s->sr;v->send=.30f;}
        if(kind==7){const float aa[6]={1,.16f,.035f,.009f,0,0};v->amp[j]=aa[j];v->attack=.014f*s->sr;v->send=.27f;}
        if(kind==8){v->step[j]=f*(j+1)/s->sr;v->amp[j]=j==0?1.f:j==1?.16f:j==2?.035f:0;v->decay[j]=expf(-1.f/((4.5f/(1+j))*s->sr));v->attack=.8f*s->sr;v->send=.68f;v->life=(uint64_t)(18*s->sr);}
        if(kind==9){const float rat[6]={1,2,3.98f,5.99f,8,10};const float aa[6]={1,.21f,.048f,.009f,0,0};v->step[j]=f*rat[j]/s->sr;v->amp[j]=aa[j];v->decay[j]=expf(-1.f/((1.9f/(1+j*.9f))*s->sr));v->attack=.060f*s->sr;v->send=.55f;v->life=(uint64_t)(10*s->sr);}
        if(f*ratio>s->sr*.42 || v->step[j]>.42)v->amp[j]=0;
    }
    s->events++;s->noteEvents++;
}
#include "SignatureScore.h"
#include "RelaxationScore.h"
#include "GravityScore.h"
#include "OrbitScore.h"
#include "SonarScore.h"
static void newMotif(OndeDSP *s){
    /* Seed chooses a composition ONCE. No note-by-note random omissions. */
    int contour=(int)(s->seed%4);
    for(int j=0;j<8;j++)s->motif[j]=contours[contour][j];
    s->pattern=0;s->primary=0;s->secondary=0;s->motifCursor=0;
}
static void nextBar(OndeDSP *s){
    if(s->bars%8==0){s->phrase++;s->motifCursor=0;}
    /* A continuous common-tone bed. Harmonic movement only on full phrases. */
    int harmonicBars=s->now[ONDE_STABILITY]>=.9f?64:32;
    if(s->now[ONDE_ORCHESTRA]>.01f)harmonicBars=s->now[ONDE_STABILITY]>=.9f?32:16;
    if(s->mode==2)harmonicBars=64;
    if(s->bars && s->bars%(uint64_t)harmonicBars==0){
        int route=(int)(s->seed%4);
        s->field=routes[route][(s->bars/harmonicBars)%8];
        s->nextPad=s->frame;
    }
    s->energyTarget=.82f; /* Never drop an entire arrangement section. */
    s->section=(int)((s->bars/32)%6); /* semantic progress, no abrupt energy change */
    s->opennessTarget=.63f+.025f*s->slow[5]*s->now[ONDE_EVOLUTION];
}
/* One shared score. Sustained inner voices and ostinati refer to the same
   modal voicing and beat clock. Sample alternation never skips a rhythmic event. */
static void orchestra_score(OndeDSP *s,int k){
    if(!s->orchestra||orc_count(s->orchestra)==0||s->now[ONDE_ORCHESTRA]<.002f)return;
    double beat=60/s->bpm;const int *chord=voicing[s->field];
    uint64_t turn=s->bars*16+k;
    if(k==0){
        orc_note(s->orchestra,2,41,.45f,.62f,beat*6.5,s->seed);
        orc_note(s->orchestra,2,48,.27f,.66f,beat*6.0,s->seed+1);
        orc_note(s->orchestra,1,chord[1],.32f,.48f,beat*6.0,s->seed+2);
        orc_note(s->orchestra,1,chord[2],.22f,.53f,beat*6.2,s->seed+3);
        orc_note(s->orchestra,0,chord[3],.26f,.25f,beat*6.0,s->seed+4);
        orc_note(s->orchestra,0,chord[4],.20f,.33f,beat*6.4,s->seed+5);
        orc_note(s->orchestra,5,53,.24f,.62f,beat*6.4,s->seed);
        orc_note(s->orchestra,5,60,.15f,.68f,beat*6.0,s->seed+1);
        orc_note(s->orchestra,6,53,.24f,.51f,beat*5.9,s->seed+2);
        orc_note(s->orchestra,7,chord[3],.21f,.43f,beat*5.9,s->seed+3);
    }
    if(s->detail>.005f && s->mode!=2){
        if(k%2==0){
            static const int low[8]={41,48,41,53,41,48,41,48};
            int index=(int)(turn/2)%8;
            float accent=k%4==0?1.f:.72f;
            orc_note(s->orchestra,3,low[index],.24f*accent,.58f,beat*.82,s->seed);
            if(s->now[ONDE_DENSITY]>.35f){
                int degree=s->motif[index]%5;
                orc_note(s->orchestra,4,chord[degree],.11f*accent,.29f,beat*.72,s->seed+1);
            }
        }
        if(k%4==2){
            int index=(int)(turn/4)%8,degree=s->motif[index]%5;
            orc_note(s->orchestra,8,chord[degree],.24f,.39f,beat*3.7,s->seed);
        }
        if(k%8==0){
            orc_note(s->orchestra,9,k==0?41:48,k==0?.37f:.22f,.51f,beat*2.9,s->seed);
            orc_note(s->orchestra,10,36,k==0?.16f:.095f,.5f,beat*1.8,s->seed);
        }
    }
}
static void sequencer(OndeDSP *s){
    int k=s->step;float density=s->now[ONDE_DENSITY],detail=s->detail;
    s->tickCount++;
    if(k==0 && !s->score)nextBar(s);
    if(k%4==0){
        s->beatCount++;
        if(s->lastBeatFrame){
            uint64_t gap=s->frame-s->lastBeatFrame;
            if(!s->minBeatGap||gap<s->minBeatGap)s->minBeatGap=gap;
            if(gap>s->maxBeatGap)s->maxBeatGap=gap;
        }
        s->lastBeatFrame=s->frame;
    }
    /* Density changes which FIXED subdivision exists, never the clock. */
    int grid=density<.15f?16:density<.48f?8:4;
    if(s->mode==1)grid=density<.23f?16:8;
    if(s->mode==2)grid=16;
    if(!s->score && k%grid==0){
        int index=(int)((s->bars*16+k)/grid)%8;
        int degree=s->motif[index];
        int midi=voicing[s->field][degree]-(s->now[ONDE_CHARACTER]>.72f && s->mode==0?12:0);
        float activity=smooth(density/.20f);
        if(s->mode==2)activity*=detail*(s->bars%4==0?1.f:0.f);
        float level=(s->mode==0?.090f:s->mode==1?.100f:.055f)*activity;
        float character=s->now[ONDE_CHARACTER];
        int kind=character>.72f?3:character>.4f?1:0;
        if(s->mode==2)kind=3;
        /* Quiet grace notes only at composed eighth-note positions; no random fills. */
        float pan=.5f+(index%2?.09f:-.09f);
        if(level>.0001f && detail>.001f)note(s,midi,kind,level*detail,pan,0);
    }
    if(s->score==GRAVITY)gravity_score(s,k);else if(s->score==ORBIT)orbit_score(s,k);else if(s->score==SONAR)sonar_score(s,k);else if(RELAXATION(s->score))relaxation_score(s,k);else if(s->score)signature_score(s,k);else orchestra_score(s,k);
    if(++s->step==16){s->step=0;s->bars++;}
}
static void grain(OndeDSP *s){
    if(s->frame<(uint64_t)(2*s->sr))return;
    Grain *g=NULL;for(int j=0;j<GRAINS;j++)if(!s->grains[j].active){g=&s->grains[j];break;}
    if(!g)return;
    memset(g,0,sizeof(*g));g->active=1;
    float seconds=.23f+.62f*uni(&s->music);
    const double speeds[6]={.5,.75,1.,1.5,-.5,1.};
    g->step=speeds[(int)(uni(&s->music)*6)];
    double behind=.42+1.0*uni(&s->music);
    if(g->step>1)behind=fmax(behind,(g->step-1)*seconds+.2);
    g->read=wrap((s->grainWrite-behind*s->sr)/MEMORY)*MEMORY;
    g->life=(uint64_t)(seconds*s->sr);g->pan=.07f+.86f*uni(&s->music);
    g->gain=(.08f+.28f*s->now[ONDE_TEXTURE]+.12f*s->now[ONDE_MOVEMENT])*
        (.60f+.4f*uni(&s->music))*s->detail;
    s->events++;s->grainEvents++;
}
static float allpass(Allpass *a,float x){
    float z=a->data[a->at],y=z-.57f*x;a->data[a->at]=x+.57f*y;
    if(++a->at==a->size)a->at=0;return y;
}
static float readDelay(const float *d,int size,double at){
    while(at<0)at+=size;while(at>=size)at-=size;
    int a=(int)at;float f=(float)(at-a);return d[a]*(1-f)+d[(a+1)&(size-1)]*f;
}
static void control(OndeDSP *s){
    int mode=atomic_load_explicit(&s->wantedMode,memory_order_relaxed);
    uint64_t seed=atomic_load_explicit(&s->wantedSeed,memory_order_relaxed);
    if(mode!=s->mode){s->mode=mode;s->sceneStart=s->frame;s->nextPad=s->frame;}
    if(seed!=s->seed){s->seed=seed;s->music.state=seed;newMotif(s);}
    int score=(int)atomic_load_explicit(&s->target[ONDE_COMPOSITION],memory_order_relaxed);
    if(score!=s->score){
        s->score=score;s->scoreStartBar=s->bars;s->nextPad=s->frame;s->planReady=0;
        if(s->frame==0 && score>0)memset(s->pads,0,sizeof(s->pads));
        if(!RELAXATION(score))memset(s->relaxVoice,0,sizeof(s->relaxVoice));
        memset(&s->gravity,0,sizeof(s->gravity));
    }
    float dt=128.f/(float)s->sr;
    s->rhythmWeight+=(1-expf(-dt/.030f))*(atomic_load_explicit(&s->rhythmTarget,memory_order_relaxed)-s->rhythmWeight);
    for(int j=0;j<7;j++)s->sectionMix[j]+=(1-expf(-dt/(s->score>=8?16.f:8.f)))*((s->planReady?s->plan.levels[j]:1.f)-s->sectionMix[j]);
    for(int j=0;j<ONDE_PARAM_COUNT;j++){
        float t=atomic_load_explicit(&s->target[j],memory_order_relaxed);
        s->now[j]+=(s->frame==0||j==ONDE_GAIN||j==ONDE_COMPOSITION?1.f:(1-expf(-dt/.65f)))*(t-s->now[j]);
    }
    s->focus+=(1-expf(-dt/2.5f))*((s->mode==0?1.f:0)-s->focus);
    s->meditation+=(1-expf(-dt/2.5f))*((s->mode==2?1.f:0)-s->meditation);
    s->sectionEnergy+=(1-expf(-dt/5.f))*(s->energyTarget-s->sectionEnergy);
    s->openness+=(1-expf(-dt/8.f))*(s->opennessTarget-s->openness);
    float evolution=s->now[ONDE_EVOLUTION];
    float wantedBass=s->score==2?.08f:s->score==3?.65f:s->score==4?.67f:s->score==5?.55f:s->score==6?.55f:1.f;
    if(RELAXATION(s->score)){const float relaxationBass[5]={.42f,.025f,.055f,.09f,.06f};wantedBass=relaxationBass[s->score-8];}
    if(BASS_LED(s->score))wantedBass=0; /* Gravity, Orbit and Sonar render its own beat-locked low end */
    s->bassMix+=(s->frame==0?1.f:(1-expf(-dt/2.f)))*(wantedBass-s->bassMix);
    s->choirMix+=(1-expf(-dt/2.f))*((s->score==4||s->score==11?1.f:0.f)-s->choirMix);
    s->bpm=s->now[ONDE_TEMPO];
    s->beatStep=s->bpm/(60*s->sr);
    s->bassStep+=(1-expf(-dt/1.8f))*(s->bassWanted-s->bassStep);
    if(s->frame>=s->nextDrift){
        s->driftTarget=noise(&s->music)*.00008f;s->airAmpTarget=.6f+.8f*uni(&s->music);
        for(int j=0;j<PADS;j++)if(s->pads[j].active)s->pads[j].driftTarget=noise(&s->music)*.00015f;
        s->nextDrift=s->frame+(uint64_t)((.8+1.8*uni(&s->music))*s->sr);
    }
    s->drift+=(1-expf(-dt/1.9f))*(s->driftTarget-s->drift);
    s->airAmp+=(1-expf(-dt/2.f))*(s->airAmpTarget-s->airAmp);
    for(int j=0;j<PADS;j++)s->pads[j].drift+=(1-expf(-dt/2.1f))*(s->pads[j].driftTarget-s->pads[j].drift);
    for(int j=0;j<6;j++){
        s->lfo[j]=wrap(s->lfo[j]+s->lfoStep[j]*128*(.7+.8*evolution));
        s->slow[j]=sn(s,s->lfo[j]);
    }
    s->detail=1;
    if(s->mode==2&&s->now[ONDE_SETTLE_MINUTES]>.1f)
        s->detail=1-smooth((float)((s->frame-s->sceneStart)/s->sr)/(60*s->now[ONDE_SETTLE_MINUTES]));
    s->lowpassCoef=1-expf(-(float)TAU*((1000+3500*s->now[ONDE_BRIGHTNESS])*(1-.40f*s->now[ONDE_WARMTH]))/(float)s->sr);
    float acousticCut=1-expf(-(float)TAU*(3100+1800*s->now[ONDE_BRIGHTNESS])/(float)s->sr);
    s->lowpassCoef+=(acousticCut-s->lowpassCoef)*s->now[ONDE_ORCHESTRA];
    if(RELAXATION(s->score)){
        float cutoff=(s->score==9?2600.f:s->score==10?2300.f:s->score==12?2200.f:1800.f)+1500*s->now[ONDE_BRIGHTNESS];
        cutoff*=1.f+.25f*(.85f-s->now[ONDE_WARMTH]);
        s->lowpassCoef=1-expf(-(float)TAU*cutoff/(float)s->sr);
    }
    s->dampingCoef=1-expf(-(float)TAU*(950+1800*s->now[ONDE_BRIGHTNESS])/(float)s->sr);
    const double secs[8]={.0311,.0377,.0433,.0491,.0573,.0677,.0793,.0899};
    float space=s->now[ONDE_SPACE];
    for(int j=0;j<LINES;j++){
        s->delayBase[j]=secs[j]*1.35*s->sr; /* fixed geometry, no zipper pitch when room size changes */
        s->feedback[j]=powf(.001f,secs[j]*1.35f/(1.9f+7.8f*space));
        s->delayPhase[j]=wrap(s->delayPhase[j]+s->delayStep[j]*128);
        float wanted=sn(s,s->delayPhase[j])*(.35f+.65f*s->now[ONDE_MOVEMENT]);
        s->delayWobbleStep[j]=(wanted-s->delayWobble[j])/128.f;
    }
    if(s->score==GRAVITY)gravity_control(s);else if(s->score==ORBIT)orbit_control(s);else if(s->score==SONAR)sonar_control(s);
    double beat=60/s->bpm;
    s->echoTimeL+=(1-expf(-dt/3.f))*(beat*1.0*s->sr-s->echoTimeL);
    s->echoTimeR+=(1-expf(-dt/3.f))*(beat*1.5*s->sr-s->echoTimeR);
}
OndeDSP *onde_dsp_create(double sr,int mode,uint64_t seed){
    if(!isfinite(sr)||sr<8000||sr>96000||mode<0||mode>2)return NULL;
    OndeDSP *s=calloc(1,sizeof(*s));if(!s)return NULL;
    s->choir=choir_create(sr);if(!s->choir){free(s);return NULL;}
    atomic_init(&s->publishedComposition,0);atomic_init(&s->publishedChoirVoices,0);atomic_init(&s->publishedSignatureEvents,0);
    s->orchestra=orc_create(sr);if(!s->orchestra){choir_destroy(s->choir);free(s);return NULL;}
    atomic_init(&s->publishedOrchestraEvents,0);atomic_init(&s->publishedOrchestraVoices,0);
    s->rhythmWeight=1;atomic_init(&s->rhythmTarget,1);
    atomic_init(&s->publishedPhrase,0);atomic_init(&s->publishedChapter,0);atomic_init(&s->publishedPlanHash,0);atomic_init(&s->publishedVariant,0);
    for(int j=0;j<7;j++)s->sectionMix[j]=1;
    s->sr=sr;s->mode=mode;s->focus=mode==0;s->meditation=mode==2;
    s->seed=seed;s->music.state=seed;s->air.state=seed^UINT64_C(0x18a394829bac);
    s->bpm=mode==0?72:mode==1?56:48;
    s->sectionEnergy=s->energyTarget=.82f;s->openness=s->opennessTarget=.65f;
    s->airAmp=s->airAmpTarget=1;s->detail=1;
    for(int j=0;j<=TABLE;j++)s->sine[j]=sin(TAU*j/TABLE);
    float init[3][ONDE_PARAM_COUNT]={
      {.30f,.16f,.12f,.54f,.04f,.64f,.12f,0,0,.78f,72,.98f,.86f,.2f},
      {.22f,.16f,.13f,.76f,.03f,.04f,.12f,0,0,.54f,56,.96f,.90f,.15f},
      {.08f,.10f,.08f,.82f,.02f,0,.06f,30,0,.58f,48,1,.95f,.90f}};
    for(int j=0;j<ONDE_PARAM_COUNT;j++){s->now[j]=init[mode][j];atomic_init(&s->target[j],init[mode][j]);}
    atomic_init(&s->wantedMode,mode);atomic_init(&s->wantedSeed,seed);
    atomic_init(&s->publishedBeats,0);atomic_init(&s->publishedTicks,0);
    atomic_init(&s->publishedMinGap,0);atomic_init(&s->publishedMaxGap,0);
    atomic_init(&s->publishedFrames,0);atomic_init(&s->publishedEvents,0);atomic_init(&s->publishedNotes,0);
    atomic_init(&s->publishedGrains,0);atomic_init(&s->publishedBars,0);
    atomic_init(&s->publishedPeak,0);atomic_init(&s->publishedRms,0);atomic_init(&s->publishedGain,0);
    atomic_init(&s->publishedBpm,s->bpm);atomic_init(&s->publishedSection,0);
    atomic_init(&s->publishedHarmony,0);atomic_init(&s->publishedVoices,0);
    if(!atomic_is_lock_free(&s->target[0])||!atomic_is_lock_free(&s->wantedSeed)){orc_destroy(s->orchestra);choir_destroy(s->choir);free(s);return NULL;}
    const double rates[6]={.0173,.0279,.0413,.0671,.1137,.0031};
    for(int j=0;j<6;j++){s->lfo[j]=uni(&s->music);s->lfoStep[j]=rates[j]/sr;}
    for(int j=0;j<8;j++){s->delayPhase[j]=uni(&s->music);s->delayStep[j]=(.09+.017*j)/sr;}
    int ll[3]={191,421,853},rr[3]={229,557,929};
    for(int j=0;j<3;j++){
        s->diffuseL[j].size=fmax(1,fmin(AP_MAX-1,ll[j]*sr/44100));
        s->diffuseR[j].size=fmax(1,fmin(AP_MAX-1,rr[j]*sr/44100));
    }
    double cut[4]={75,280,1100,3400};
    for(int j=0;j<4;j++)s->airCoef[j]=1-expf(-(float)TAU*cut[j]/sr);
    s->bassStep=s->bassWanted=hz(29)/sr;
    s->echoTimeL=(60/s->bpm)*1.0*sr;s->echoTimeR=(60/s->bpm)*1.5*sr;
    s->nextStep=0;s->nextPad=(uint64_t)(7*sr);s->nextGrain=(uint64_t)(2.5*sr);
    newMotif(s);
    for(int j=0;j<5;j++)pad(s,voicing[0][j]-(j==0?12:0),j<2?.034f:.024f,1);
    control(s);return s;
}
void onde_dsp_destroy(OndeDSP *s){if(s){orc_destroy(s->orchestra);choir_destroy(s->choir);}free(s);}
int onde_dsp_add_sample(OndeDSP *s,int instrument,int root,int rr,const float *left,const float *right,uint32_t frames,double rate){
    if(!s||s->frame!=0)return 0;return orc_add(s->orchestra,instrument,root,rr,left,right,frames,rate);
}
int onde_dsp_add_pcm16_sample(OndeDSP *s,int instrument,int root,int rr,const int16_t *pcm,uint32_t frames,double rate){
    if(!s||s->frame!=0)return 0;return orc_add_pcm16(s->orchestra,instrument,root,rr,pcm,frames,rate);
}
int onde_dsp_add_shared_sample(OndeDSP *s,int instrument,int root,int rr,OndeSampleBuffer *buffer){
    if(!s||s->frame!=0)return 0;return orc_add_shared(s->orchestra,instrument,root,rr,buffer);
}
int onde_dsp_orchestra_samples(const OndeDSP *s){return s?orc_count(s->orchestra):0;}
int onde_dsp_orchestra_families(const OndeDSP *s){return s?orc_families(s->orchestra):0;}
int onde_dsp_orchestra_voices(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedOrchestraVoices,memory_order_relaxed):0;}
uint64_t onde_dsp_orchestra_events(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedOrchestraEvents,memory_order_relaxed):0;}
void onde_dsp_set(OndeDSP *s,int p,float v){
    if(p==ONDE_COMPOSITION && (!isfinite(v)||v!=floorf(v)))return;
    if(s&&p>=0&&p<ONDE_PARAM_COUNT&&isfinite(v))
        atomic_store_explicit(&s->target[p],cl(v,p==ONDE_TEMPO?40:0,(p==ONDE_SETTLE_MINUTES||p==ONDE_TEMPO)?120:p==ONDE_COMPOSITION?SONAR:1),memory_order_relaxed);
}
void onde_dsp_set_mode(OndeDSP *s,int m){if(s&&m>=0&&m<=2)atomic_store_explicit(&s->wantedMode,m,memory_order_relaxed);}
void onde_dsp_set_seed(OndeDSP *s,uint64_t seed){if(s)atomic_store_explicit(&s->wantedSeed,seed,memory_order_relaxed);}
void onde_dsp_render(OndeDSP *s,float *left,float *right,uint32_t count){
    if(!s||!left||!right)return;
    float peak=0;double energy=0;
    const float up=1-expf(-1.f/(.85f*s->sr)),down=1-expf(-1.f/(.10f*s->sr));
    const float dc=expf(-(float)TAU*14/(float)s->sr);
    const float eCoef=1-expf(-(float)TAU*1900/(float)s->sr);
    const float gCoef=1-expf(-(float)TAU*2300/(float)s->sr);
    const float bassFall=expf(-1.f/(.24f*s->sr));
    for(uint32_t n=0;n<count;n++,s->frame++){
        if((s->frame&127)==0)control(s);
        if(s->frame>=s->nextStep){
            sequencer(s);s->nextStep+=(60/s->bpm)*s->sr/4;
        }
        if(!s->score && s->frame>=s->nextPad){
            /* Staggered, voiced chord blooms, not synchronous chord blocks. */
            for(int j=0;j<3;j++){
                int k=(j+(int)(s->bars%5))%5;
                pad(s,voicing[s->field][k]-(s->mode==2&&k==4?12:0),
                    (.024f+.015f*s->now[ONDE_DENSITY])*(.75f+.35f*s->sectionEnergy),0);
            }
            s->nextPad=s->frame+(uint64_t)((60/s->bpm)*16*s->sr);
        }
        if(0 && s->frame>=s->nextGrain){ /* granular texture removed: no pitch-shifted fragments */
            if(s->detail>.02f&&s->section!=3)grain(s);
            double interval=(s->mode==0?.38:s->mode==1?.70:2.1)*(1.2-.7*s->now[ONDE_TEXTURE])*(.7+.8*uni(&s->music));
            s->nextGrain=s->frame+(uint64_t)(interval*s->sr);
        }
        float l=0,r=0,sendL=0,sendR=0,echoSendL=0,echoSendR=0;
        float bright=s->now[ONDE_BRIGHTNESS],move=s->now[ONDE_MOVEMENT],space=s->now[ONDE_SPACE],detail=s->detail;
        float w=noise(&s->air),wl=.6f*w+.4f*noise(&s->air),wr=.6f*w+.4f*noise(&s->air);
        for(int j=0;j<PADS;j++){
            Pad *v=&s->pads[j];if(!v->active)continue;
            if(v->age>=v->life){v->active=0;continue;}
            float env=smooth((float)v->age/v->attack)*smooth((float)(v->life-v->age)/v->release);
            float a=osc(s,&v->p,v->step*(1+v->drift*(.25+move)));
            float b=osc(s,&v->q,v->step*v->detune*(1+s->drift));
            float t=osc(s,&v->t,v->step*.5003);
            /* Morph a soft reed/string spectrum, with two independently moving formants. */
            float morph=cl(.5f+.22f*s->slow[j%4]+.28f*v->color,.08f,1);
            float harmonics=(.06f+.10f*bright)*sn(s,wrap(v->p*2))+
                (.018f+.04f*morph)*sn(s,wrap(v->p*3))+
                (.007f+.022f*bright*(1+s->slow[(j+1)%4]))*sn(s,wrap(v->p*5))+
                .005f*bright*sn(s,wrap(v->p*7));
            float breath=.97f+.02f*s->slow[(j+2)%4]+.01f*s->slow[4];
            float raw=(.68f*a+.29f*b+.03f*t+harmonics);
            v->tone+=.09f*(raw-v->tone);
            float x=v->tone*env*v->amp*breath*(1-.94f*s->now[ONDE_ORCHESTRA])*(1.30f+.32f*s->now[ONDE_TEXTURE]);
            float p=cl(v->pan+.085f*move*s->slow[(j+1)%4],.05f,.95f);
            float width=(a-b)*env*v->amp*breath*(1-.94f*s->now[ONDE_ORCHESTRA])*(.25f+.55f*space);
            float pl=(x+width)*(1-p)*1.45f,pr=(x-width)*p*1.45f;
            l+=pl;r+=pr;sendL+=pl*.60f;sendR+=pr*.60f;v->age++;
        }
        if(RELAXATION(s->score)){float bl=0,br=0;relaxation_frame(s,&bl,&br);l+=bl;r+=br;sendL+=bl*.48f;sendR+=br*.48f;}
        if(s->score==GRAVITY)gravity_frame(s,&l,&r,&sendL,&sendR);else if(s->score==ORBIT)orbit_frame(s,&l,&r,&sendL,&sendR);else if(s->score==SONAR)sonar_frame(s,&l,&r,&sendL,&sendR);
        /* Energy rack: a beat-locked impact plus an eighth-note bass ostinato.
           Original synthesis only. Zero-valued controls preserve the legacy timbre.
           No white noise, clipping-based distortion or randomized drum omissions. */
        /* Relaxation has no rhythm rack; Gravity renders its own in gravity_frame. */
        float drive=s->score>=8?0:s->now[ONDE_DRIVE]*s->focus*s->rhythmWeight;
        float punch=s->score>=8?0:s->now[ONDE_PUNCH]*s->focus*s->rhythmWeight;
        // A disabled rhythm rack must not compute kick exponentials and
        // harmonics on all 44,100 samples/second. Phase advancement stays below.
        if(drive>0 || punch>0){
        float beatSeconds=(float)(s->beatPhase*60.0/s->bpm);
        float beatDuration=(float)(60.0/s->bpm);
        float attack=smooth(beatSeconds/.010f);
        float decay=expf(-beatSeconds/.155f);
        float tail=smooth((beatDuration-beatSeconds)/.040f);
        float kickEnvelope=attack*decay*tail;
        double kickCycles=43.6535*beatSeconds+1.12*(1-exp(-beatSeconds/.028));
        float kick=(sn(s,wrap(kickCycles))+.32f*sn(s,wrap(kickCycles*2)))*kickEnvelope;
        float half=(float)wrap(s->beatPhase*2);
        float halfSeconds=half*beatDuration*.5f;
        float rollEnvelope=smooth(halfSeconds/.016f)*expf(-halfSeconds/.150f)*smooth((beatDuration*.5f-halfSeconds)/.028f);
        float accent=s->beatPhase<.5?1.f:.72f;
        if(s->score && s->planReady){
            /* The kick remains an anchor; the upper-bass accents answer across
               eight bars instead of identical eighth notes for the whole session. */
            static const float bassAccents[4][8]={
                {1,.67f,.87f,.56f,.95f,.72f,.84f,.62f},
                {1,.58f,.91f,.71f,.89f,.64f,.95f,.55f},
                {1,.74f,.82f,.62f,.94f,.55f,.88f,.70f},
                {1,.62f,.94f,.55f,.85f,.73f,.92f,.65f}
            };
            uint64_t localBar=s->bars-s->scoreStartBar;
            int halfBeat=((s->step+15)%16)/2;
            int phraseVariant=(s->plan.variant+(localBar%8>=4?1:0))%4;
            accent*=bassAccents[phraseVariant][halfBeat];
        }
        float harmonicBody=sn(s,wrap(s->bassPhase*2))+.44f*sn(s,wrap(s->bassPhase*3))+.24f*sn(s,wrap(s->bassPhase*4))+.085f*sn(s,wrap(s->bassPhase*6));
        float motion=(.070f+.28f*s->now[ONDE_BASS])*drive*rollEnvelope*accent*harmonicBody;
        float impact=(.16f+.35f*s->now[ONDE_BASS])*punch*kick;
        /* The background breathes around the attacks rather than masking them. */
        float duck=1.f-(.34f*punch+.16f*drive)*kickEnvelope;
        l*=duck;r*=duck;sendL*=duck;sendR*=duck;
        l+=(impact+motion)*s->bassMix;r+=(impact+motion)*s->bassMix;
        }
        /* Smooth continuous sub, 43.65 Hz + octave. Mono, no pitch glide, no hiss.
           Pulse and its harmonics are phase-locked; never random kick omissions. */
        float sub=osc(s,&s->bassPhase,s->bassStep);
        float harm=sn(s,wrap(s->bassPhase*2));
        float bassAmount=s->now[ONDE_BASS];
        float pulse=s->now[ONDE_PULSE]*(s->mode==2?detail:1.f)*s->rhythmWeight;
        float raised=.5f+.5f*sn(s,wrap(s->beatPhase-.25));
        float beatShape=raised*raised;
        float bed=(.070f+.090f*bassAmount)*(1.f-.32f*drive);
        float breathing=1.f-.025f*move+(.025f*move)*s->slow[0];
        float envelope=(1.f-.64f*pulse)+(.90f*pulse)*beatShape;
        float bass=(sub+(.24f+.10f*bassAmount)*harm)*bed*envelope*breathing;
        s->beatPhase=wrap(s->beatPhase+s->beatStep);
        bass*=s->bassMix;l+=bass;r+=bass;
        for(int j=0;j<NOTES;j++){
            Note *v=&s->notes[j];if(!v->active)continue;
            if(v->delay){v->delay--;continue;}
            if(v->age>=v->life){v->active=0;continue;}
            float x=0;
            for(int k=0;k<6;k++)if(v->amp[k]!=0){
                x+=osc(s,&v->p[k],v->step[k]*(1+s->drift))*v->amp[k]*v->env[k];
                v->env[k]*=v->decay[k];
            }
            /* Pure resonator timbres: no generated click/brush noise. */
            v->nlp+=.12f*(x-v->nlp);x=v->nlp;
            v->noiseEnv*=v->noiseDecay;
            float tail=smooth((float)(v->life-v->age)/(.22f*s->sr));
            x*=smooth((float)v->age/v->attack)*tail*v->gain*(s->score>=8?1.f:(1-.95f*s->now[ONDE_ORCHESTRA]))*s->rhythmWeight;
            if(v->kind<5)x*=detail;
            float pl=x*(1-v->pan)*1.4f,pr=x*v->pan*1.4f;
            l+=pl;r+=pr;sendL+=pl*v->send;sendR+=pr*v->send;
            if(v->kind<4||v->kind>=6){echoSendL+=pl*.38f;echoSendR+=pr*.38f;}
            v->age++;
        }
        /* Real acoustic families share the hall and stable electronic foundation. */
        float levels[7]={s->now[ONDE_STRINGS],s->now[ONDE_BRASS],s->now[ONDE_WOODS],s->now[ONDE_HARP]*detail,s->now[ONDE_OSTINATO]*detail,s->now[ONDE_PERCUSSION]*detail,s->now[ONDE_PIANO]*detail};
        for(int j=0;j<7;j++){levels[j]*=s->sectionMix[j];if(j>=3)levels[j]*=s->rhythmWeight;}
        float acousticL=0,acousticR=0;
        orc_frame(s->orchestra,levels,s->now[ONDE_WARMTH],&acousticL,&acousticR);
        float orchestralGain=s->now[ONDE_ORCHESTRA];
        float acousticCalibration=s->score==2?2.10f:s->score==3?1.50f:s->score==5?1.35f:1.f;
        if(RELAXATION(s->score)){const float relCal[5]={1,2.0f,1.6f,1.1f,1.35f};acousticCalibration=relCal[s->score-8];}
        acousticL*=orchestralGain*acousticCalibration;acousticR*=orchestralGain*acousticCalibration;
        l+=acousticL;r+=acousticR;sendL+=acousticL*.40f;sendR+=acousticR*.40f;
        float vocalL=0,vocalR=0;
        if(s->choirMix>.00001f){
            float morph=s->score==11?1.55f+.32f*s->slow[5]:1.0f+.82f*s->slow[5];choir_frame(s->choir,morph,&vocalL,&vocalR);
            float gain=s->now[ONDE_VOCALS]*s->choirMix;
            vocalL*=gain;vocalR*=gain;l+=vocalL;r+=vocalR;sendL+=vocalL*.95f;sendR+=vocalR*.95f;
        }
        /* Granular texture recycles ONLY this engine's own freshly synthesized material. */
        s->grainMemory[s->grainWrite]=(l+r)*.5f-bass*.6f;
        s->grainWrite=(s->grainWrite+1)&(MEMORY-1);
        for(int j=0;j<GRAINS;j++){
            Grain *g=&s->grains[j];if(!g->active)continue;
            if(g->age>=g->life){g->active=0;continue;}
            float window=.5f-.5f*sn(s,wrap((double)g->age/g->life+.25));
            float x=readDelay(s->grainMemory,MEMORY,g->read);
            g->lp+=gCoef*(x-g->lp);x=g->lp*window*g->gain*detail;
            float pl=x*(1-g->pan)*1.5f,pr=x*g->pan*1.5f;
            l+=pl;r+=pr;sendL+=pl;sendR+=pr;
            g->read+=g->step;while(g->read<0)g->read+=MEMORY;while(g->read>=MEMORY)g->read-=MEMORY;
            g->age++;
        }
        float al=0,ar=0;const float weights[4]={.65f,.42f,.23f,.075f};
        for(int j=0;j<4;j++){
            s->airL[j]+=s->airCoef[j]*(wl-s->airL[j]);s->airR[j]+=s->airCoef[j]*(wr-s->airR[j]);
            al+=s->airL[j]*weights[j];ar+=s->airR[j]*weights[j];
        }
        float airGain=0; /* No hiss layer. Grain control colors harmonic bed instead. */
        l+=al*airGain;r+=ar*airGain;sendL+=al*airGain*.6f;sendR+=ar*airGain*.6f;
        /* Musical, filtered cross echoes: opposing answers, not a wash over the bass. */
        float el=readDelay(s->echoL,ECHO,s->echoWrite-s->echoTimeL);
        float er=readDelay(s->echoR,ECHO,s->echoWrite-s->echoTimeR);
        s->echoLP_L+=eCoef*(el-s->echoLP_L);s->echoLP_R+=eCoef*(er-s->echoLP_R);
        s->echoHP_L+=.009f*(s->echoLP_L-s->echoHP_L);s->echoHP_R+=.009f*(s->echoLP_R-s->echoHP_R);
        el=s->echoLP_L-s->echoHP_L;er=s->echoLP_R-s->echoHP_R;
        float fb=.25f+.22f*space;
        s->echoL[s->echoWrite]=echoSendL+er*fb;s->echoR[s->echoWrite]=echoSendR+el*fb;
        s->echoWrite=(s->echoWrite+1)&(ECHO-1);
        float echoGain=(.10f+.20f*space);
        l+=el*echoGain;r+=er*echoGain;sendL+=el*.24f;sendR+=er*.24f;
        for(int j=0;j<3;j++){sendL=allpass(&s->diffuseL[j],sendL);sendR=allpass(&s->diffuseR[j],sendR);}
        float rd[8],mx[8];
        for(int j=0;j<8;j++){
            s->delayWobble[j]+=s->delayWobbleStep[j];
            float x=readDelay(s->delay[j],DELAY,s->writeAt-s->delayBase[j]-s->delayWobble[j]);
            s->damping[j]+=s->dampingCoef*(x-s->damping[j]);rd[j]=mx[j]=s->damping[j];
        }
        for(int k=1;k<8;k*=2)for(int a=0;a<8;a+=k*2)for(int b=0;b<k;b++){
            float x=mx[a+b],y=mx[a+b+k];mx[a+b]=x+y;mx[a+b+k]=x-y;
        }
        for(int j=0;j<8;j++)s->delay[j][s->writeAt]=(j&1?sendR:sendL)*(j&2?-.17f:.17f)+mx[j]*.35355339059f*s->feedback[j];
        s->writeAt=(s->writeAt+1)&(DELAY-1);
        float wet=.42f+.65f*space;
        l+=(rd[0]+rd[2]-rd[4]+rd[6])*.5f*wet;r+=(rd[1]-rd[3]+rd[5]+rd[7])*.5f*wet;
        s->toneL+=s->lowpassCoef*(l-s->toneL);s->toneR+=s->lowpassCoef*(r-s->toneR);
        s->tone2L+=s->lowpassCoef*(s->toneL-s->tone2L);s->tone2R+=s->lowpassCoef*(s->toneR-s->tone2R);
        l=s->tone2L-s->dcPrevL+dc*s->dcL;r=s->tone2R-s->dcPrevR+dc*s->dcR;
        s->dcPrevL=s->tone2L;s->dcPrevR=s->tone2R;s->dcL=l;s->dcR=r;
        float target=s->now[ONDE_GAIN];s->master+=(target>s->master?up:down)*(target-s->master);
        /* Reserve headroom for articulated bass instead of relying on the safety ceiling. */
        float calibration=(.85f+.05f*s->meditation)/(1.f+.35f*drive+.15f*punch);
        static const float collectionGain[SONAR+1]={1,.95f,1.50f,1.10f,1.23f,1.75f,1.90f,.90f, 0.96f,1.65f,1.22f,1.23f,1.45f, 0.60f,0.60f,0.60f};
        calibration*=collectionGain[s->score];
        l*=s->master*calibration;r*=s->master*calibration;
        if(fabsf(l)>.78f)l=copysignf(.78f+.17f*(1-expf(-(fabsf(l)-.78f)/.17f)),l);
        if(fabsf(r)>.78f)r=copysignf(.78f+.17f*(1-expf(-(fabsf(r)-.78f)/.17f)),r);
        if(!isfinite(l))l=0;if(!isfinite(r))r=0;
        left[n]=l;right[n]=r;peak=fmaxf(peak,fmaxf(fabsf(l),fabsf(r)));energy+=(double)l*l+(double)r*r;
    }
    atomic_store_explicit(&s->publishedPhrase,s->planReady?s->plan.phrase:0,memory_order_relaxed);
    atomic_store_explicit(&s->publishedChapter,s->planReady?s->plan.chapter:0,memory_order_relaxed);
    atomic_store_explicit(&s->publishedPlanHash,s->planReady?s->plan.fingerprint:0,memory_order_relaxed);
    atomic_store_explicit(&s->publishedVariant,s->planReady?s->plan.variant:0,memory_order_relaxed);
    atomic_store_explicit(&s->publishedComposition,s->score,memory_order_relaxed);
    atomic_store_explicit(&s->publishedSignatureEvents,s->signatureEvents,memory_order_relaxed);
    atomic_store_explicit(&s->publishedChoirVoices,choir_voices(s->choir),memory_order_relaxed);
    atomic_store_explicit(&s->publishedOrchestraEvents,orc_events(s->orchestra),memory_order_relaxed);
    atomic_store_explicit(&s->publishedOrchestraVoices,orc_voices(s->orchestra),memory_order_relaxed);
    int voices=orc_voices(s->orchestra);for(int j=0;j<RELAX_VOICES;j++)voices+=s->relaxVoice[j].active;for(int j=0;j<PADS;j++)voices+=s->pads[j].active;
    for(int j=0;j<NOTES;j++)voices+=s->notes[j].active;for(int j=0;j<GRAINS;j++)voices+=s->grains[j].active;
    for(int j=0;j<GRAVITY_VOICES;j++)voices+=s->gravity.voice[j].active;
    atomic_store_explicit(&s->publishedBeats,s->beatCount,memory_order_relaxed);
    atomic_store_explicit(&s->publishedTicks,s->tickCount,memory_order_relaxed);
    atomic_store_explicit(&s->publishedMinGap,s->minBeatGap,memory_order_relaxed);
    atomic_store_explicit(&s->publishedMaxGap,s->maxBeatGap,memory_order_relaxed);
    atomic_store_explicit(&s->publishedFrames,s->frame,memory_order_relaxed);
    atomic_store_explicit(&s->publishedEvents,s->events,memory_order_relaxed);
    atomic_store_explicit(&s->publishedNotes,s->noteEvents,memory_order_relaxed);
    atomic_store_explicit(&s->publishedGrains,s->grainEvents,memory_order_relaxed);
    atomic_store_explicit(&s->publishedBars,s->bars,memory_order_relaxed);
    atomic_store_explicit(&s->publishedSection,s->section,memory_order_relaxed);
    atomic_store_explicit(&s->publishedHarmony,s->field,memory_order_relaxed);
    atomic_store_explicit(&s->publishedVoices,voices,memory_order_relaxed);
    atomic_store_explicit(&s->publishedBpm,s->bpm,memory_order_relaxed);
    atomic_store_explicit(&s->publishedPeak,peak,memory_order_relaxed);
    atomic_store_explicit(&s->publishedRms,count?sqrtf(energy/(2.*count)):0,memory_order_relaxed);
    atomic_store_explicit(&s->publishedGain,s->master,memory_order_relaxed);
}
uint64_t onde_dsp_frames(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedFrames,memory_order_relaxed):0;}
uint64_t onde_dsp_events(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedEvents,memory_order_relaxed):0;}
float onde_dsp_peak(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedPeak,memory_order_relaxed):0;}
float onde_dsp_rms(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedRms,memory_order_relaxed):0;}
float onde_dsp_gain(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedGain,memory_order_relaxed):0;}
uint64_t onde_dsp_note_events(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedNotes,memory_order_relaxed):0;}
uint64_t onde_dsp_grain_events(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedGrains,memory_order_relaxed):0;}
uint64_t onde_dsp_bars(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedBars,memory_order_relaxed):0;}
int onde_dsp_section(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedSection,memory_order_relaxed):0;}
int onde_dsp_harmony(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedHarmony,memory_order_relaxed):0;}
int onde_dsp_voices(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedVoices,memory_order_relaxed):0;}
float onde_dsp_bpm(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedBpm,memory_order_relaxed):0;}

uint64_t onde_dsp_beats(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedBeats,memory_order_relaxed):0;}
uint64_t onde_dsp_ticks(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedTicks,memory_order_relaxed):0;}
uint64_t onde_dsp_min_beat_gap(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedMinGap,memory_order_relaxed):0;}
uint64_t onde_dsp_max_beat_gap(const OndeDSP *s){return s?atomic_load_explicit(&s->publishedMaxGap,memory_order_relaxed):0;}

int onde_dsp_composition(const OndeDSP*s){return s?atomic_load_explicit(&s->publishedComposition,memory_order_relaxed):0;}
uint64_t onde_dsp_signature_events(const OndeDSP*s){return s?atomic_load_explicit(&s->publishedSignatureEvents,memory_order_relaxed):0;}
int onde_dsp_choir_voices(const OndeDSP*s){return s?atomic_load_explicit(&s->publishedChoirVoices,memory_order_relaxed):0;}

uint64_t onde_dsp_phrase(const OndeDSP*s){return s?atomic_load_explicit(&s->publishedPhrase,memory_order_relaxed):0;}
uint64_t onde_dsp_chapter(const OndeDSP*s){return s?atomic_load_explicit(&s->publishedChapter,memory_order_relaxed):0;}
uint64_t onde_dsp_plan_hash(const OndeDSP*s){return s?atomic_load_explicit(&s->publishedPlanHash,memory_order_relaxed):0;}
int onde_dsp_variant(const OndeDSP*s){return s?atomic_load_explicit(&s->publishedVariant,memory_order_relaxed):0;}
void onde_dsp_set_rhythm_weight(OndeDSP*s,float weight){if(s&&isfinite(weight))atomic_store_explicit(&s->rhythmTarget,cl(weight,0,1),memory_order_relaxed);}
uint64_t onde_dsp_frames_to_bar(const OndeDSP*s){
 if(!s||s->bpm<=0)return 0;
 double offset=s->nextStep+((16-s->step)%16)*(60/s->bpm)*s->sr/4-(double)s->frame;
 return offset>0?(uint64_t)ceil(offset):0;
}
