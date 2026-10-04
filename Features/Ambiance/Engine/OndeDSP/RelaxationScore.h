/* Original scores for a small relaxation collection. No audio from a streaming
 * service is used. Breath-like movement is musical, not measured respiration. */
static void relaxed_chord(OndeDSP *s, const int *ch) {
    static const float bed[5]={.085f,.030f,.022f,.028f,.048f};
    const float weight[5]={.80f,.87f,1.f,.76f,.50f};
    int style=s->score-8;
    /* Common tones retain phase and level. Only changed voices crossfade. */
    for(int i=0;i<RELAX_VOICES;i++) if(s->relaxVoice[i].active) {
        int keep=0;
        for(int j=0;j<5;j++) if(s->relaxVoice[i].midi==ch[j]) keep=1;
        if(!keep) s->relaxVoice[i].target=0;
    }
    for(int j=0;j<5;j++) {
        RelaxVoice *v=NULL;
        for(int i=0;i<RELAX_VOICES;i++) if(s->relaxVoice[i].active && s->relaxVoice[i].midi==ch[j]) {v=&s->relaxVoice[i];break;}
        if(!v) {
            for(int i=0;i<RELAX_VOICES;i++) if(!s->relaxVoice[i].active) {v=&s->relaxVoice[i];break;}
            if(!v) continue;
            memset(v,0,sizeof(*v));v->active=1;v->midi=ch[j];
            v->phase=wrap(j*.183+.13);v->second=wrap(j*.293+.37);
            v->step=hz(ch[j])/s->sr;v->pan=.23f+j*.135f;
            s->events++;
        }
        v->target=bed[style]*weight[j];
    }
}
static void relaxation_prepare(OndeDSP *s,int k) {
    uint64_t bar=s->bars-s->scoreStartBar,phrase=bar/8;
    if(!s->planReady || (k==0 && bar%8==0 && phrase!=s->plan.phrase)) {
        if(onde_relaxation_plan(s->score,s->seed,phrase,s->now[ONDE_EVOLUTION],&s->plan)) {
            s->planReady=1;s->field=s->plan.harmony;s->section=s->plan.section;
            s->bassWanted=hz(29)/s->sr;
            relaxed_chord(s,s->plan.chord);
        }
    }
}
static void relaxation_score(OndeDSP *s,int k) {
    relaxation_prepare(s,k);
    const int *ch=s->plan.chord;uint64_t bar=s->bars-s->scoreStartBar;
    int b=(int)(bar%8),a=s->plan.melody[b*2],z=s->plan.melody[b*2+1];
    double beat=60/s->bpm;float detail=s->detail,density=s->now[ONDE_DENSITY];
    /* Density alters the strength of the composed detail, not the tempo.
       At zero the sustained harmonic setting continues without small notes. */
    float presence=(smooth(density/.35f)+.25f*fmaxf(0,density-.35f)/.65f)*detail;
    float arc=b<4?1.f:.90f;
    if(s->score==8) {
        /* Lagoon: continuous common-tone synthesizer, distant slow blooms.
           No repeated kick or required noise/nature layer. */
        if(presence>.00001f && k==4 && (b==1||b==5)) note(s,ch[a],8,.037f*presence,.44f,0);
        if(presence>.00001f && k==10 && b==6) note(s,ch[z],8,.028f*presence,.57f,0);
    } else if(s->score==9) {
        /* Stillwater: a sparse piano sentence, not a metronomic left hand. */
        static const int first[8]={0,4,2,6,0,4,2,8};
        static const int answer[8]={10,12,10,-1,10,12,14,-1};
        if(k==first[b]) orc_note(s->orchestra,11,ch[a],.32f*presence*arc,.51f,beat*7,s->seed);
        if(k==answer[b]) orc_note(s->orchestra,11,ch[z],.22f*presence*arc,.54f,beat*6,s->seed);
        if(k==0 && (b==0||b==4)) orc_note(s->orchestra,11,b==0?41:48,.22f*presence,.45f,beat*9,s->seed);
        if(k==0 && b==0) orc_note_legato(s->orchestra,2,41,.10f,.58f,beat*32+6,6,s->seed);
    } else if(s->score==10) {
        /* Hearth: low chamber ensemble, distributed legato renewals. */
        if(b==0) {
            double length=beat*32+7;
            if(k==0){orc_note_legato(s->orchestra,2,41,.23f,.58f,length,7,s->seed);orc_note_legato(s->orchestra,2,48,.15f,.61f,length,7,s->seed+1);}
            if(k==2){orc_note_legato(s->orchestra,1,ch[1],.20f,.46f,length,7,s->seed);orc_note_legato(s->orchestra,1,ch[2],.14f,.51f,length,7,s->seed+1);}
            if(k==4){orc_note_legato(s->orchestra,0,ch[3],.16f,.33f,length,7,s->seed);orc_note_legato(s->orchestra,5,53,.13f,.63f,length,7,s->seed);}
            if(k==6)orc_note_legato(s->orchestra,6,ch[0]-12,.18f,.52f,length,7,s->seed);
        }
        if(k==4 && (b==2||b==6)) orc_note_legato(s->orchestra,7,ch[a],.10f*presence,.53f,beat*9,2.5,s->seed);
    } else if(s->score==11) {
        /* Reverie: wordless choir connected by common tones; no sung text.
           Common singers hold their phase through harmony changes. */
        if(k==0){int voices[4]={ch[0],ch[1],ch[2],ch[3]};choir_chord(s->choir,voices,3.5);}
        if(b==0 && k==0)orc_note_legato(s->orchestra,2,41,.12f,.58f,beat*32+7,7,s->seed);
        if(k==6 && (b==1||b==5))orc_note(s->orchestra,8,ch[a],.14f*presence,.47f,beat*7,s->seed);
        if(k==10 && b==6)orc_note(s->orchestra,8,ch[z],.10f*presence,.55f,beat*7,s->seed);
    } else if(s->score==12) {
        /* Driftwood: two interlocking, low wooden/harp gestures with room to ring. */
        static const int slots[8]={0,4,2,6,0,4,2,8};
        if(presence>.00001f && k==slots[b])note(s,ch[a]-(a>2?12:0),9,.085f*presence*arc,.42f,0);
        if(presence>.00001f && k==10 && b%2==0)note(s,ch[z],9,.055f*presence,.57f,0);
        if(k==12 && (b==1||b==4||b==6))orc_note(s->orchestra,8,ch[z],.21f*presence,.52f,beat*7,s->seed);
        if(b==0&&k==0)orc_note_legato(s->orchestra,2,41,.11f,.58f,beat*32+6,6,s->seed);
    }
    s->signatureEvents++;
}
static void relaxation_frame(OndeDSP *s,float *l,float *r) {
    if(s->score<8) return;
    const float step=1-expf(-1.f/(3.2f*(float)s->sr));
    float bright=s->now[ONDE_BRIGHTNESS],space=s->now[ONDE_SPACE];
    for(int i=0;i<RELAX_VOICES;i++) {
        RelaxVoice *v=&s->relaxVoice[i];if(!v->active)continue;
        v->gain+=step*(v->target-v->gain);
        if(v->target==0 && v->gain<.000002f){v->active=0;continue;}
        float a=osc(s,&v->phase,v->step),b=osc(s,&v->second,v->step*1.00016);
        float harmonics=(.12f+.12f*bright)*sn(s,wrap(v->phase*2))+.045f*sn(s,wrap(v->phase*3));
        /* Very shallow color movement, no fast tremolo or imposed breathing cadence. */
        float swell=.975f+.025f*s->slow[5];
        float x=(.78f*a+.22f*b+harmonics)*v->gain*swell;
        float side=(a-b)*v->gain*(.11f+.16f*space);
        *l+=(x+side)*sqrtf(1-v->pan);*r+=(x-side)*sqrtf(v->pan);
    }
}
