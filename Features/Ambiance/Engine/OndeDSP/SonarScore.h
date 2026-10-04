/* Sonar (score 15): a bass-led Focus score in a minimal deep-techno style.
 * Original synthesis; MIT code, CC0 audio.
 *
 * Same production rules as Gravity and Orbit, with its own sound. It reuses
 * Gravity's state, never its code, so neither earlier piece can change:
 *  - One oscillator, restarted by the sequencer on every beat, is both the
 *    tight kick and the sustained G1 sub: every beat has the same low end.
 *  - An offbeat bass line answers each kick. It is a bright waveform through a
 *    resonant low-pass filter that opens on accents and drifts slowly over
 *    minutes: the sound changes, the notes do not.
 *  - A dark, open chord drone carries the metrical tremolo (16 Hz at 120 BPM)
 *    and ducks lightly under the kick. Texture 0 removes the tremolo.
 *  - Seven glassy pings per eight bars feed the beat-synchronous echo; soft
 *    pitched ticks mark the offbeats. No noise layer, voice, drop or fill.
 */
static void sonar_chord(OndeDSP *s, const int *ch) {
    static const float weight[5]={1.f,.86f,.74f,.66f,.52f};
    static const float pan[5]={.50f,.22f,.78f,.14f,.86f};
    static const double cents[5]={.60,.90,.55,1.05,.80};
    Gravity *g=&s->gravity;
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
            v->a=wrap(j*.157+.23);v->b=wrap(j*.271+.59);
            double detune=pow(2.,cents[j]/1200.),step=hz(ch[j])/s->sr;
            v->stepA=step*detune;v->stepB=step/detune;
            v->left=sqrtf(1-pan[j]);v->right=sqrtf(pan[j]);v->colour=.25f;
            s->events++;
        }
        v->target=weight[j];
    }
}
static void sonar_prepare(OndeDSP *s, int k) {
    uint64_t bar=s->bars-s->scoreStartBar,phrase=bar/8;
    if(!s->planReady || (k==0 && bar%8==0 && phrase!=s->plan.phrase)) {
        int first=!s->planReady;
        if(onde_sonar_plan(s->score,s->seed,phrase,s->now[ONDE_EVOLUTION],&s->plan)) {
            s->planReady=1;s->field=s->plan.harmony;s->section=s->plan.section;
            s->bassWanted=hz(31)/s->sr; /* stationary G1 pedal, 49 Hz */
            if(first) s->bassStep=s->bassWanted;
            sonar_chord(s,s->plan.chord);
        }
    }
}
/* One note of the filtered bass line. The oscillator phase runs on, so a new
   pitch never clicks; G2 realigns with the sub's second harmonic when the
   previous note has died away. */
static void sonar_note(OndeDSP *s, int midi, float accent, int sixteenths) {
    Gravity *g=&s->gravity;
    double sixteenth=15.*s->sr/s->bpm;
    if(midi==43 && g->acidAmp<.02f) g->roll=wrap(g->low*2);
    g->rollStep=hz(midi)/s->sr;
    double life=sixteenth*sixteenths-.012*s->sr;
    g->rollLife=(uint32_t)(life>.004*s->sr?life:.004*s->sr);
    g->rollAge=0;g->rollLevel=accent;g->rollOn=1;g->acidFilter=1;s->events++;
}
static void sonar_score(OndeDSP *s, int k) {
    sonar_prepare(s,k);
    if(k%4==0) gravity_beat(s);
    const int *ch=s->plan.chord;uint64_t bar=s->bars-s->scoreStartBar;
    int b=(int)(bar%8),a=s->plan.melody[b*2],z=s->plan.melody[b*2+1];
    float detail=s->detail,density=s->now[ONDE_DENSITY];
    /* A one-bar riff that never lands on the beat: offbeat accents, a short
       answer, an octave and a minor third. Only bars four and eight change
       its last sixteenth. */
    static const int riff[16]={-1,-1,0,0,-1,-1,12,0,-1,-1,0,3,-1,-1,0,-2};
    static const float accent[16]={0,0,1.f,.62f,0,0,.70f,.58f,0,0,.92f,.64f,0,0,.74f,.60f};
    if(riff[k]>-1 || k==15) {
        int midi=k==15?s->plan.bass[b]:43+riff[k];
        sonar_note(s,midi,accent[k],1);
    }
    /* Seven glassy pings in eight bars, at fixed places, and an open bar. */
    float notes=smooth(density/.30f)*detail,presence=notes*s->sectionMix[1];
    if(bar>=8 && presence>.0001f) {
        float level=(.040f+.030f*density)*presence,arc=b<4?1.f:.90f;
        if(k==12 && b%2==0) note(s,ch[a],2,level*arc,.38f,0);
        if(k==6 && b%2==1 && b!=7) note(s,ch[z],2,level*.80f*arc,.64f,0);
        if(density>.60f && k==14 && b%2==0 && b!=6) note(s,ch[z],2,level*.50f,.55f,0);
    }
    /* Soft pitched ticks on every offbeat once the piece is established. */
    if(k%4==2 && bar>=16 && notes>.0001f)
        note(s,88,4,.075f*notes*s->sectionMix[5]*(.5f+s->now[ONDE_PUNCH]),k==2||k==10?.44f:.58f,0);
    s->signatureEvents++;
}
static void sonar_control(OndeDSP *s) {
    Gravity *g=&s->gravity;const float sr=(float)s->sr,dt=128.f/sr;
    g->sweepCoef=expf(-1.f/(.020f*sr));
    g->thumpCoef=expf(-1.f/(.120f*sr));
    g->pumpCoef=expf(-1.f/((.100f+.120f*s->now[ONDE_PULSE])*sr));
    g->glide=1-expf(-1.f/(4.0f*sr));
    g->slew=1-expf(-1.f/(.0015f*sr));
    g->tailCoef=expf(-1.f/(.0015f*sr));
    g->rollDecay[0]=1-expf(-1.f/(.003f*sr));  /* bass-line attack  */
    g->rollDecay[1]=1-expf(-1.f/(.016f*sr));  /* bass-line release */
    g->rollDecay[2]=expf(-1.f/(.110f*sr));    /* filter envelope   */
    static const int divisions[4]={8,12,16,24};
    float best=1e9f;
    for(int j=0;j<4;j++) {
        float distance=fabsf(logf(divisions[j]*(float)s->bpm/960.f));
        if(distance<best) {best=distance;g->division=divisions[j];}
    }
    float bars=(float)(s->bars-s->scoreStartBar)+s->step/16.f;
    const float wanted[3]={smooth(bars/2.f),smooth((bars-2.f)/4.f),smooth((bars-4.f)/8.f)};
    for(int j=0;j<3;j++) g->entrance[j]+=(s->frame==0?1.f:1-expf(-dt/.5f))*(wanted[j]-g->entrance[j]);
    float base=.14f+.26f*s->now[ONDE_BRIGHTNESS]+.03f*s->slow[5];
    float depth=.025f+.08f*s->now[ONDE_MOVEMENT];
    for(int i=0;i<GRAVITY_VOICES;i++) if(g->voice[i].active)
        g->voice[i].colour=cl(base+depth*s->slow[(g->voice[i].slot+3)%5],.04f,.55f);
}
static void sonar_frame(OndeDSP *s, float *l, float *r, float *sendL, float *sendR) {
    Gravity *g=&s->gravity;
    const float rhythm=s->rhythmWeight,weight=s->focus*rhythm;
    const float bassAmount=s->now[ONDE_BASS],punch=s->now[ONDE_PUNCH],pulse=s->now[ONDE_PULSE];
    const float beat=(float)(60./s->bpm),t=(float)g->age/(float)s->sr;
    const float live=g->armed?1.f:0.f;
    /* Low oscillator: falls from about 140 Hz onto G1 in the first 60 ms. */
    float x1=sn(s,g->low),x2=sn(s,g->low*2),x3=sn(s,g->low*3),x4=sn(s,g->low*4);
    g->low+=s->bassStep*(1.+1.9*g->sweep);if(g->low>=1)g->low-=floor(g->low);
    /* When a live tempo change shortens the beat, the end-of-beat fade can only
       fall over a few milliseconds instead of stepping down. */
    float wantedTail=smooth((beat-t)/.034f);
    if(wantedTail>=g->tailEnv) g->tailEnv=wantedTail;
    else g->tailEnv+=(1-expf(-1.f/(.004f*(float)s->sr)))*(wantedTail-g->tailEnv);
    float attack=smooth(t/.004f),tail=g->tailEnv;
    float knock=g->sweep;
    float kick=(x1+.28f*knock*x2+.10f*knock*x3)*attack*g->thump*tail;
    float rise=fminf(.090f+.300f*pulse,.62f*beat);
    float sustain=smooth((t-.065f)/rise)*tail;
    float harmonics=s->sectionMix[4];
    float sub=(x1+(.28f+.12f*bassAmount)*harmonics*x2+harmonics*(1.f+.30f*s->slow[0])*(.12f*x3+.05f*x4))*sustain;
    float breathing=1.f-.025f*s->now[ONDE_MOVEMENT]*(1.f-s->slow[0]);
    g->lowLast=((.40f+.78f*bassAmount)*punch*weight*kick
               +(.080f+.104f*bassAmount)*(.4f+.6f*rhythm)*breathing*sub)*live;
    float low=g->lowLast+g->lowTail;
    g->lowTail=fabsf(g->lowTail)<1e-9f?0:g->lowTail*g->tailCoef;
    /* Filtered bass line. A smooth amplitude follower replaces hard note
       edges; the filter state runs on between notes. */
    float gate=0;
    if(g->rollOn) {
        if(g->rollAge>=g->rollLife) g->rollOn=0;
        else {gate=g->rollLevel;g->rollAge++;}
    }
    g->acidAmp+=(gate>g->acidAmp?g->rollDecay[0]:g->rollDecay[1])*(gate-g->acidAmp);
    float line=0;
    if(g->acidAmp>1e-6f || fabsf(g->acidLow)>1e-7f || fabsf(g->acidBand)>1e-7f) {
        /* A bright harmonic series whose partials fall by 0.82 each. */
        const float c=.82f;
        float saw=sn(s,g->roll)/(1+c*c-2*c*sn(s,g->roll+.25))*(1-c*c)*.5f;
        g->roll+=g->rollStep;if(g->roll>=1)g->roll-=floor(g->roll);
        /* The cutoff opens on each note, more on accents, and its centre drifts
           over several minutes; Brightness raises it, Movement deepens the drift. */
        float drift=.78f+(.30f+.15f*s->now[ONDE_MOVEMENT])*s->slow[5]+.08f*s->slow[0];
        float centre=(120.f+360.f*s->now[ONDE_BRIGHTNESS])*drift*s->sectionMix[2];
        float cutoff=centre*(1.f+(1.3f+1.7f*g->rollLevel)*g->acidFilter);
        cutoff=cl(cutoff,40.f,fminf(1800.f,.11f*(float)s->sr));
        float f=2.f*sinf(3.14159265f*cutoff/(float)s->sr),q=.40f;
        float x=saw*g->acidAmp;
        g->acidLow+=f*g->acidBand;
        float high=x-g->acidLow-q*g->acidBand;
        g->acidBand+=f*high;
        if(!isfinite(g->acidLow)||!isfinite(g->acidBand)||fabsf(g->acidLow)>8.f){g->acidLow=0;g->acidBand=0;}
        line=g->acidLow*(.115f+.38f*bassAmount)*s->now[ONDE_DRIVE]*weight*g->entrance[1]*s->sectionMix[3];
    }
    g->acidFilter*=g->rollDecay[2];
    /* Chord drone: two oscillators per voice, about a cent apart. */
    float padL=0,padR=0,width=.70f+.30f*s->now[ONDE_SPACE];
    for(int i=0;i<GRAVITY_VOICES;i++) {
        GravityVoice *v=&g->voice[i];if(!v->active)continue;
        v->gain+=g->glide*(v->target-v->gain);
        if(v->target==0 && v->gain<.000002f){v->active=0;continue;}
        float cc=v->colour,even=1+cc*cc,odd=2*cc,scale=(1-cc*cc)*.5f*v->gain;
        float a=sn(s,v->a)/(even-odd*sn(s,v->a+.25));
        float b=sn(s,v->b)/(even-odd*sn(s,v->b+.25));
        v->a+=v->stepA;if(v->a>=1)v->a-=1;
        v->b+=v->stepB;if(v->b>=1)v->b-=1;
        float mid=(a+b)*scale,side=(a-b)*scale*width;
        padL+=(mid+side)*v->left;padR+=(mid-side)*v->right;
    }
    /* A lighter pump than Orbit: the drone only leans away from the kick. */
    g->pump*=g->pumpCoef;
    float duck=1.f-(.18f+.30f*punch)*weight*attack*g->pump*live;
    float amount=cl(.9f*s->now[ONDE_TEXTURE],0,.9f)*g->entrance[2]*rhythm;
    float cycle=.5f-.5f*sn(s,wrap((double)t/beat*g->division)+.25);
    g->tremolo+=g->slew*((1.f-amount*cycle)/(1.f-.5f*amount)-g->tremolo);
    float shape=.070f*g->entrance[0]*s->sectionMix[0]*duck*g->tremolo;
    padL*=shape;padR*=shape;
    *l+=padL+low+line;*r+=padR+low+line;
    /* Drier than Gravity and Orbit: less of the drone reaches the reverb. */
    *sendL+=padL*.42f+line*.05f;*sendR+=padR*.42f+line*.05f;
    g->sweep*=g->sweepCoef;g->thump*=g->thumpCoef;g->age++;
}
