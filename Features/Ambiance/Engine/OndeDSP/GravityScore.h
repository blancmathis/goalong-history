/* Gravity (score 13): a bass-led Focus score. Original synthesis; MIT code, CC0 audio.
 *
 * Production choices, informed by published studies but not validated by them:
 *  - The pulse lives in the low register. One oscillator, restarted by the
 *    sequencer on every beat, is both the soft kick and the sustained sub, so
 *    every beat starts from the same phase with the same pitch fall and level.
 *    Nothing in the low end drifts, and it shares one clock with the notes.
 *  - An offbeat bass answers each kick. Its decaying harmonics keep the line
 *    audible on speakers that cannot reproduce a 44 Hz fundamental.
 *  - A slow chord layer breathes around the kick. A metrical tremolo (a whole
 *    number of cycles per beat, 16 Hz at 120 BPM) is applied to that layer only;
 *    its energy sits roughly between 200 Hz and 1 kHz. Texture 0 removes it.
 *  - No drops, fills, random omissions, noise layer or clipping. Layers arrive
 *    during the first bars and then stay.
 */
static void gravity_chord(OndeDSP *s, const int *ch) {
    static const float weight[5]={1.f,.84f,.92f,.80f,.62f};
    static const float pan[5]={.50f,.26f,.74f,.16f,.84f};
    static const double cents[5]={.50,.70,.45,.85,.65};
    Gravity *g=&s->gravity;
    /* Common tones keep their phase and level. Only changed voices crossfade. */
    for(int i=0;i<GRAVITY_VOICES;i++) if(g->voice[i].active) {
        int keep=0;
        for(int j=0;j<5;j++) if(g->voice[i].midi==ch[j]) keep=1;
        if(!keep) g->voice[i].target=0;
    }
    for(int j=0;j<5;j++) {
        GravityVoice *v=NULL;
        for(int i=0;i<GRAVITY_VOICES;i++) if(g->voice[i].active && g->voice[i].midi==ch[j]) {v=&g->voice[i];break;}
        if(!v) {
            for(int i=0;i<GRAVITY_VOICES;i++) if(!g->voice[i].active) {v=&g->voice[i];break;}
            if(!v) continue;
            memset(v,0,sizeof(*v));v->active=1;v->midi=ch[j];v->slot=j;
            v->a=wrap(j*.183+.13);v->b=wrap(j*.293+.37);
            double detune=pow(2.,cents[j]/1200.),step=hz(ch[j])/s->sr;
            v->stepA=step*detune;v->stepB=step/detune;
            v->left=sqrtf(1-pan[j]);v->right=sqrtf(pan[j]);v->colour=.4f;
            s->events++;
        }
        v->target=weight[j];
    }
}
static void gravity_prepare(OndeDSP *s, int k) {
    uint64_t bar=s->bars-s->scoreStartBar,phrase=bar/8;
    if(!s->planReady || (k==0 && bar%8==0 && phrase!=s->plan.phrase)) {
        if(onde_gravity_plan(s->score,s->seed,phrase,s->now[ONDE_EVOLUTION],&s->plan)) {
            s->planReady=1;s->field=s->plan.harmony;s->section=s->plan.section;
            s->bassWanted=hz(29)/s->sr; /* stationary F1 pedal */
            gravity_chord(s,s->plan.chord);
        }
    }
}
/* One monophonic bass note. A note is always released before the next one
   starts; the short tail only guards a live tempo change. */
static void gravity_note(OndeDSP *s, int midi, float accent, int sixteenths) {
    static const float partial[6]={1.f,.50f,.30f,.18f,.10f,.05f};
    Gravity *g=&s->gravity;
    double sixteenth=15.*s->sr/s->bpm;
    float colour=(.50f+.95f*s->now[ONDE_BRIGHTNESS])*s->sectionMix[2]
        *(1.f+.16f*s->slow[1]*(.4f+s->now[ONDE_MOVEMENT]));
    if(g->rollOn) g->rollTail=g->rollLast;
    /* F2 starts in phase with the sub's second harmonic, at any tempo. */
    g->roll=midi==41?wrap(g->low*2):0;g->rollStep=hz(midi)/s->sr;
    for(int j=0;j<6;j++) {g->rollEnv[j]=1;g->rollAmp[j]=partial[j]*(j==0?1.f:colour);}
    g->rollAttack=(float)(.009*s->sr);g->rollRelease=(float)(.016*s->sr);
    double life=sixteenth*sixteenths-.010*s->sr,least=g->rollAttack+g->rollRelease+1;
    g->rollLife=(uint32_t)(life>least?life:least);
    g->rollAge=0;g->rollLevel=accent;g->rollOn=1;s->events++;
}
/* The sequencer starts every beat, so kick, sub, bass line and notes share one
   clock even while the tempo is changing. The tail absorbs what little level
   is left when a live tempo change shortens a beat. */
static void gravity_beat(OndeDSP *s) {
    Gravity *g=&s->gravity;
    g->lowTail+=g->lowLast;
    g->low=0;g->sweep=1;g->thump=1;g->pump=1;g->age=0;g->armed=1;
}
static void gravity_score(OndeDSP *s, int k) {
    gravity_prepare(s,k);
    if(k%4==0) gravity_beat(s);
    const int *ch=s->plan.chord;uint64_t bar=s->bars-s->scoreStartBar;
    int b=(int)(bar%8),a=s->plan.melody[b*2],z=s->plan.melody[b*2+1];
    float detail=s->detail,density=s->now[ONDE_DENSITY];
    /* The bass answers every kick on the offbeat. Two pickups per bar lead into
       beats three and one; only the last pickup of bars four and eight moves. */
    if(k%4==2) gravity_note(s,41,1.f,(k==6||k==14)?1:2);
    if(k==7) gravity_note(s,41,.56f,1);
    if(k==15) gravity_note(s,s->plan.bass[b],.56f,1);
    /* Seven soft notes in eight bars, at fixed places, and an open last bar.
       Density sets their level; at zero the bass and chords continue alone. */
    float notes=smooth(density/.30f)*detail,presence=notes*s->sectionMix[1];
    if(bar>=8 && presence>.0001f) {
        float level=(.050f+.036f*density)*presence,arc=b<4?1.f:.90f;
        if(k==6 && b%2==0) note(s,ch[a],9,level*arc,.42f,0);
        if(b%2==1 && b!=7 && k==(b==3?10:12)) note(s,ch[z],9,level*.78f*arc,.60f,0);
        if(density>.60f && k==14 && b%2==0 && b!=6) note(s,ch[z],9,level*.50f,.53f,0);
    }
    /* A quiet wooden backbeat marks two and four once the piece is established. */
    if((k==4||k==12) && bar>=16 && notes>.0001f)
        note(s,65,7,.012f*notes*s->sectionMix[5]*(.5f+s->now[ONDE_PUNCH]),.5f,0);
    s->signatureEvents++;
}
/* Control rate: coefficients, entrances and slow colour. No allocation. */
static void gravity_control(OndeDSP *s) {
    Gravity *g=&s->gravity;const float sr=(float)s->sr,dt=128.f/sr;
    g->sweepCoef=expf(-1.f/(.026f*sr));
    g->thumpCoef=expf(-1.f/(.150f*sr));
    g->pumpCoef=expf(-1.f/((.110f+.130f*s->now[ONDE_PULSE])*sr));
    g->glide=1-expf(-1.f/(2.6f*sr));
    g->slew=1-expf(-1.f/(.0015f*sr));
    g->tailCoef=expf(-1.f/(.0015f*sr));
    for(int j=0;j<6;j++) g->rollDecay[j]=expf(-1.f/((.26f/(1.f+.75f*j))*sr));
    /* A whole number of tremolo cycles per beat, whichever lands nearest 16 Hz,
       so the modulation stays on the metrical grid at any tempo. */
    static const int divisions[4]={8,12,16,24};
    float best=1e9f;
    for(int j=0;j<4;j++) {
        float distance=fabsf(logf(divisions[j]*(float)s->bpm/960.f));
        if(distance<best) {best=distance;g->division=divisions[j];}
    }
    /* Chords first, the bass line from bar three, the tremolo from bar five. */
    float bars=(float)(s->bars-s->scoreStartBar)+s->step/16.f;
    const float wanted[3]={smooth(bars/2.f),smooth((bars-2.f)/4.f),smooth((bars-4.f)/8.f)};
    for(int j=0;j<3;j++) g->entrance[j]+=(s->frame==0?1.f:1-expf(-dt/.5f))*(wanted[j]-g->entrance[j]);
    /* Each chord voice drifts in colour on its own slow cycle, and the whole
       layer follows a tide of several minutes. The notes themselves hold still. */
    float base=.26f+.42f*s->now[ONDE_BRIGHTNESS]+.05f*s->slow[5];
    float depth=.035f+.11f*s->now[ONDE_MOVEMENT];
    for(int i=0;i<GRAVITY_VOICES;i++) if(g->voice[i].active)
        g->voice[i].colour=cl(base+depth*s->slow[(g->voice[i].slot+1)%5],.05f,.72f);
}
static void gravity_frame(OndeDSP *s, float *l, float *r, float *sendL, float *sendR) {
    Gravity *g=&s->gravity;
    const float rhythm=s->rhythmWeight,weight=s->focus*rhythm;
    const float bassAmount=s->now[ONDE_BASS],punch=s->now[ONDE_PUNCH],pulse=s->now[ONDE_PULSE];
    /* Time since the sequencer's last beat. Nothing sounds before the first one. */
    const float beat=(float)(60./s->bpm),t=(float)g->age/(float)s->sr;
    const float live=g->armed?1.f:0.f;
    /* Low oscillator: the pitch falls from about 130 Hz onto the F1 pedal in the
       first 80 ms of every beat, then holds. Kick and sub share this one phase. */
    float x1=sn(s,g->low),x2=sn(s,g->low*2),x3=sn(s,g->low*3),x4=sn(s,g->low*4);
    g->low+=s->bassStep*(1.+2.0*g->sweep);if(g->low>=1)g->low-=floor(g->low);
    float attack=smooth(t/.0045f),tail=smooth((beat-t)/.034f);
    float knock=g->sweep;
    float kick=(x1+.30f*knock*x2+.12f*knock*x3)*attack*g->thump*tail;
    float rise=fminf(.100f+.320f*pulse,.62f*beat);
    float sustain=smooth((t-.080f)/rise)*tail;
    float harmonics=s->sectionMix[4];
    float sub=(x1+(.30f+.14f*bassAmount)*harmonics*x2+harmonics*(1.f+.35f*s->slow[0])*(.15f*x3+.06f*x4))*sustain;
    float breathing=1.f-.025f*s->now[ONDE_MOVEMENT]*(1.f-s->slow[0]);
    g->lowLast=((.34f+.66f*bassAmount)*punch*weight*kick
               +(.070f+.090f*bassAmount)*(.4f+.6f*rhythm)*breathing*sub)*live;
    float low=g->lowLast+g->lowTail;
    g->lowTail=fabsf(g->lowTail)<1e-9f?0:g->lowTail*g->tailCoef;
    /* Offbeat bass: six harmonics, the upper ones fading first. */
    float line=g->rollTail;
    g->rollTail=fabsf(g->rollTail)<1e-9f?0:g->rollTail*g->tailCoef;
    if(g->rollOn) {
        if(g->rollAge>=g->rollLife) g->rollOn=0;
        else {
            float x=0;
            for(int j=0;j<6;j++) {x+=sn(s,g->roll*(j+1))*g->rollAmp[j]*g->rollEnv[j];g->rollEnv[j]*=g->rollDecay[j];}
            g->roll+=g->rollStep;if(g->roll>=1)g->roll-=floor(g->roll);
            float envelope=smooth(g->rollAge/g->rollAttack)*smooth((g->rollLife-g->rollAge)/g->rollRelease);
            g->rollLast=x*envelope*g->rollLevel*(.055f+.18f*bassAmount)*s->now[ONDE_DRIVE]*weight
                *g->entrance[1]*s->sectionMix[3];
            line+=g->rollLast;g->rollAge++;
        }
    }
    /* Chord layer: two oscillators per voice, about a cent apart, so each note
       drifts across the stereo field over several seconds. Each oscillator is a
       closed-form harmonic series whose partials fall by the factor `colour`. */
    float padL=0,padR=0,width=.55f+.45f*s->now[ONDE_SPACE];
    for(int i=0;i<GRAVITY_VOICES;i++) {
        GravityVoice *v=&g->voice[i];if(!v->active)continue;
        v->gain+=g->glide*(v->target-v->gain);
        if(v->target==0 && v->gain<.000002f){v->active=0;continue;}
        float c=v->colour,even=1+c*c,odd=2*c,scale=(1-c*c)*.5f*v->gain;
        float a=sn(s,v->a)/(even-odd*sn(s,v->a+.25));
        float b=sn(s,v->b)/(even-odd*sn(s,v->b+.25));
        v->a+=v->stepA;if(v->a>=1)v->a-=1;
        v->b+=v->stepB;if(v->b>=1)v->b-=1;
        float mid=(a+b)*scale,side=(a-b)*scale*width;
        padL+=(mid+side)*v->left;padR+=(mid-side)*v->right;
    }
    /* The chords duck under each kick and return within the beat. */
    g->pump*=g->pumpCoef;
    float duck=1.f-(.22f+.34f*punch)*weight*attack*g->pump*live;
    /* Metrical tremolo, fullest on every subdivision. Mean level is preserved. */
    float amount=cl(.9f*s->now[ONDE_TEXTURE],0,.9f)*g->entrance[2]*rhythm;
    float cycle=.5f-.5f*sn(s,wrap((double)t/beat*g->division)+.25);
    g->tremolo+=g->slew*((1.f-amount*cycle)/(1.f-.5f*amount)-g->tremolo);
    float shape=.062f*g->entrance[0]*s->sectionMix[0]*duck*g->tremolo;
    padL*=shape;padR*=shape;
    *l+=padL+low+line;*r+=padR+low+line;
    *sendL+=padL*.55f;*sendR+=padR*.55f;
    g->sweep*=g->sweepCoef;g->thump*=g->thumpCoef;g->age++;
}
