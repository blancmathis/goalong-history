/* Orbit (score 14): the warm sibling of Gravity. Original synthesis; MIT code, CC0 audio.
 *
 * Same production rules as Gravity, in a different style (deep house and dub
 * rather than dark minimal techno). It reuses Gravity's state, never its code,
 * so Gravity's audio cannot change when Orbit is tuned:
 *  - One oscillator, restarted by the sequencer on every beat, is both the
 *    rounded kick and the sustained A1 sub: every beat has the same low end.
 *  - An offbeat A2 bass answers each kick; its harmonics keep it audible on
 *    small speakers. It starts in phase with the sub's second harmonic.
 *  - A warm, organ-like chord layer pumps under each kick and carries the same
 *    metrical tremolo (16 Hz at 120 BPM) as Gravity's chords. Texture 0 removes it.
 *  - Seven soft electric-piano notes per eight bars feed a dub echo.
 *  - No drops, fills, random omissions, noise layer or voice.
 */
static void orbit_chord(OndeDSP *s, const int *ch) {
    static const float weight[5]={1.f,.80f,.88f,.78f,.60f};
    static const float pan[5]={.50f,.30f,.70f,.20f,.80f};
    static const double cents[5]={1.6,2.2,1.4,2.6,1.9};
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
            v->a=wrap(j*.211+.07);v->b=wrap(j*.337+.41);
            double detune=pow(2.,cents[j]/1200.),step=hz(ch[j])/s->sr;
            v->stepA=step*detune;v->stepB=step/detune;
            v->left=sqrtf(1-pan[j]);v->right=sqrtf(pan[j]);v->colour=.3f;
            s->events++;
        }
        v->target=weight[j];
    }
}
static void orbit_prepare(OndeDSP *s, int k) {
    uint64_t bar=s->bars-s->scoreStartBar,phrase=bar/8;
    if(!s->planReady || (k==0 && bar%8==0 && phrase!=s->plan.phrase)) {
        int first=!s->planReady;
        if(onde_orbit_plan(s->score,s->seed,phrase,s->now[ONDE_EVOLUTION],&s->plan)) {
            s->planReady=1;s->field=s->plan.harmony;s->section=s->plan.section;
            s->bassWanted=hz(33)/s->sr; /* stationary A1 pedal, 55 Hz */
            if(first) s->bassStep=s->bassWanted; /* no glide from the engine's F1 */
            orbit_chord(s,s->plan.chord);
        }
    }
}
/* One monophonic offbeat bass note, rounder and longer than Gravity's. */
static void orbit_note(OndeDSP *s, int midi, float accent, int sixteenths) {
    static const float partial[6]={1.f,.62f,.26f,.12f,.05f,.02f};
    Gravity *g=&s->gravity;
    double sixteenth=15.*s->sr/s->bpm;
    float colour=(.55f+.85f*s->now[ONDE_BRIGHTNESS])*s->sectionMix[2]
        *(1.f+.14f*s->slow[2]*(.4f+s->now[ONDE_MOVEMENT]));
    if(g->rollOn) g->rollTail=g->rollLast;
    /* A2 starts in phase with the sub's second harmonic, at any tempo. */
    g->roll=midi==45?wrap(g->low*2):0;g->rollStep=hz(midi)/s->sr;
    for(int j=0;j<6;j++) {g->rollEnv[j]=1;g->rollAmp[j]=partial[j]*(j==0?1.f:colour);}
    g->rollAttack=(float)(.006*s->sr);g->rollRelease=(float)(.022*s->sr);
    double life=sixteenth*sixteenths-.012*s->sr,least=g->rollAttack+g->rollRelease+1;
    g->rollLife=(uint32_t)(life>least?life:least);
    g->rollAge=0;g->rollLevel=accent;g->rollOn=1;s->events++;
}
static void orbit_score(OndeDSP *s, int k) {
    orbit_prepare(s,k);
    if(k%4==0) gravity_beat(s);
    const int *ch=s->plan.chord;uint64_t bar=s->bars-s->scoreStartBar;
    int b=(int)(bar%8),a=s->plan.melody[b*2],z=s->plan.melody[b*2+1];
    float detail=s->detail,density=s->now[ONDE_DENSITY];
    /* An eighth note of bass on every offbeat. Only the last offbeat of bars
       four and eight steps away from A, and the next one returns. */
    if(k%4==2) orbit_note(s,(k==14&&(b==3||b==7))?s->plan.bass[b]:45,k==2||k==10?1.f:.84f,2);
    /* Seven soft electric-piano notes in eight bars, at fixed places, and an
       open last bar. Density sets their level; at zero the rest continues. */
    float notes=smooth(density/.30f)*detail,presence=notes*s->sectionMix[1];
    if(bar>=8 && presence>.0001f) {
        float level=(.046f+.034f*density)*presence,arc=b<4?1.f:.90f;
        if(k==10 && b%2==0) note(s,ch[a],6,level*arc,.40f,0);
        if(k==4 && b%2==1 && b!=7) note(s,ch[z],6,level*.80f*arc,.62f,0);
        if(density>.60f && k==14 && b%2==0 && b!=6) note(s,ch[z],6,level*.50f,.55f,0);
    }
    /* A soft pitched tick on two and four once the piece is established. */
    if((k==4||k==12) && bar>=16 && notes>.0001f)
        note(s,81,4,.11f*notes*s->sectionMix[5]*(.5f+s->now[ONDE_PUNCH]),.56f,0);
    s->signatureEvents++;
}
static void orbit_control(OndeDSP *s) {
    Gravity *g=&s->gravity;const float sr=(float)s->sr,dt=128.f/sr;
    g->sweepCoef=expf(-1.f/(.022f*sr));
    g->thumpCoef=expf(-1.f/(.130f*sr));
    g->pumpCoef=expf(-1.f/((.150f+.150f*s->now[ONDE_PULSE])*sr));
    g->glide=1-expf(-1.f/(2.6f*sr));
    g->slew=1-expf(-1.f/(.0015f*sr));
    g->tailCoef=expf(-1.f/(.0015f*sr));
    for(int j=0;j<6;j++) g->rollDecay[j]=expf(-1.f/((.36f/(1.f+.60f*j))*sr));
    /* Same rule as Gravity: whole tremolo cycles per beat, nearest to 16 Hz. */
    static const int divisions[4]={8,12,16,24};
    float best=1e9f;
    for(int j=0;j<4;j++) {
        float distance=fabsf(logf(divisions[j]*(float)s->bpm/960.f));
        if(distance<best) {best=distance;g->division=divisions[j];}
    }
    float bars=(float)(s->bars-s->scoreStartBar)+s->step/16.f;
    const float wanted[3]={smooth(bars/2.f),smooth((bars-2.f)/4.f),smooth((bars-4.f)/8.f)};
    for(int j=0;j<3;j++) g->entrance[j]+=(s->frame==0?1.f:1-expf(-dt/.5f))*(wanted[j]-g->entrance[j]);
    /* Darker, rounder chords than Gravity's, drifting slowly in colour. */
    float base=.16f+.30f*s->now[ONDE_BRIGHTNESS]+.04f*s->slow[5];
    float depth=.03f+.09f*s->now[ONDE_MOVEMENT];
    for(int i=0;i<GRAVITY_VOICES;i++) if(g->voice[i].active)
        g->voice[i].colour=cl(base+depth*s->slow[(g->voice[i].slot+2)%5],.04f,.60f);
}
static void orbit_frame(OndeDSP *s, float *l, float *r, float *sendL, float *sendR) {
    Gravity *g=&s->gravity;
    const float rhythm=s->rhythmWeight,weight=s->focus*rhythm;
    const float bassAmount=s->now[ONDE_BASS],punch=s->now[ONDE_PUNCH],pulse=s->now[ONDE_PULSE];
    const float beat=(float)(60./s->bpm),t=(float)g->age/(float)s->sr;
    const float live=g->armed?1.f:0.f;
    /* Low oscillator: falls from about 140 Hz onto A1 in the first 70 ms. */
    float x1=sn(s,g->low),x2=sn(s,g->low*2),x3=sn(s,g->low*3);
    g->low+=s->bassStep*(1.+1.6*g->sweep);if(g->low>=1)g->low-=floor(g->low);
    float attack=smooth(t/.004f),tail=smooth((beat-t)/.034f);
    float knock=g->sweep;
    float kick=(x1+.22f*knock*x2+.08f*knock*x3)*attack*g->thump*tail;
    float rise=fminf(.090f+.300f*pulse,.62f*beat);
    float sustain=smooth((t-.070f)/rise)*tail;
    float harmonics=s->sectionMix[4];
    float sub=(x1+(.22f+.12f*bassAmount)*harmonics*x2+.10f*harmonics*(1.f+.30f*s->slow[0])*x3)*sustain;
    float breathing=1.f-.025f*s->now[ONDE_MOVEMENT]*(1.f-s->slow[0]);
    g->lowLast=((.34f+.66f*bassAmount)*punch*weight*kick
               +(.064f+.084f*bassAmount)*(.4f+.6f*rhythm)*breathing*sub)*live;
    float low=g->lowLast+g->lowTail;
    g->lowTail=fabsf(g->lowTail)<1e-9f?0:g->lowTail*g->tailCoef;
    float line=g->rollTail;
    g->rollTail=fabsf(g->rollTail)<1e-9f?0:g->rollTail*g->tailCoef;
    if(g->rollOn) {
        if(g->rollAge>=g->rollLife) g->rollOn=0;
        else {
            float x=0;
            for(int j=0;j<6;j++) {x+=sn(s,g->roll*(j+1))*g->rollAmp[j]*g->rollEnv[j];g->rollEnv[j]*=g->rollDecay[j];}
            g->roll+=g->rollStep;if(g->roll>=1)g->roll-=floor(g->roll);
            float envelope=smooth(g->rollAge/g->rollAttack)*smooth((g->rollLife-g->rollAge)/g->rollRelease);
            g->rollLast=x*envelope*g->rollLevel*(.050f+.16f*bassAmount)*s->now[ONDE_DRIVE]*weight
                *g->entrance[1]*s->sectionMix[3];
            line+=g->rollLast;g->rollAge++;
        }
    }
    /* Chord layer: an organ-like blend, a soft harmonic series plus a quiet
       octave, on two oscillators a couple of cents apart per voice. */
    float padL=0,padR=0,width=.60f+.40f*s->now[ONDE_SPACE];
    for(int i=0;i<GRAVITY_VOICES;i++) {
        GravityVoice *v=&g->voice[i];if(!v->active)continue;
        v->gain+=g->glide*(v->target-v->gain);
        if(v->target==0 && v->gain<.000002f){v->active=0;continue;}
        float c=v->colour,even=1+c*c,odd=2*c,scale=(1-c*c)*.5f*v->gain;
        float a=sn(s,v->a)/(even-odd*sn(s,v->a+.25))+.20f*sn(s,v->a*2);
        float b=sn(s,v->b)/(even-odd*sn(s,v->b+.25))+.20f*sn(s,v->b*2);
        v->a+=v->stepA;if(v->a>=1)v->a-=1;
        v->b+=v->stepB;if(v->b>=1)v->b-=1;
        float mid=(a+b)*scale,side=(a-b)*scale*width;
        padL+=(mid+side)*v->left;padR+=(mid-side)*v->right;
    }
    /* A deeper pump than Gravity: the chords breathe around every kick. */
    g->pump*=g->pumpCoef;
    float duck=1.f-(.30f+.36f*punch)*weight*attack*g->pump*live;
    float amount=cl(.9f*s->now[ONDE_TEXTURE],0,.9f)*g->entrance[2]*rhythm;
    float cycle=.5f-.5f*sn(s,wrap((double)t/beat*g->division)+.25);
    g->tremolo+=g->slew*((1.f-amount*cycle)/(1.f-.5f*amount)-g->tremolo);
    float shape=.060f*g->entrance[0]*s->sectionMix[0]*duck*g->tremolo;
    padL*=shape;padR*=shape;
    *l+=padL+low+line;*r+=padR+low+line;
    *sendL+=padL*.62f;*sendR+=padR*.62f;
    g->sweep*=g->sweepCoef;g->thump*=g->thumpCoef;g->age++;
}
