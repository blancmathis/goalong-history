/* Seven authored identities, with eight-bar melodic arcs and 64-bar orchestration.
   Infinite refers to continuous scheduling without an end/restart, NOT no repetition. */
static int signature_id(OndeDSP*s){return s->score;}
static void signature_prepare(OndeDSP*s,int k){
 uint64_t bar=s->bars-s->scoreStartBar, phrase=bar/8;
 if(!s->planReady||(k==0&&bar%8==0&&phrase!=s->plan.phrase)){
  if(onde_phrase_plan(s->score,s->seed,phrase,s->now[ONDE_EVOLUTION],&s->plan)){
   s->planReady=1;s->field=s->plan.harmony;s->section=s->plan.section;
   /* Bass inversions follow the harmony, with the DSP's existing slow glide. */
   s->bassWanted=hz(29)/s->sr; /* stationary sub-pedal; acoustic inversions carry the harmonic movement */
  }
 }
}
static const int *signature_chord(OndeDSP*s){return s->plan.chord;}
static void signature_bed(OndeDSP*s,const int*ch,float level){
 for(int j=0;j<4;j++)pad(s,ch[j],level*(j<2?1.f:.66f),0);
}
static void signature_score(OndeDSP*s,int k){
 signature_prepare(s,k);int id=s->score;const int*ch=signature_chord(s);
 uint64_t bar=s->bars-s->scoreStartBar;int b=(int)(bar%8);double beat=60/s->bpm;
 float detail=s->detail,density=s->now[ONDE_DENSITY];
 int a=s->plan.melody[b*2],z=s->plan.melody[b*2+1];
 float arc=.92f+.08f*(b==2||b==5?1.f:b==7?-.5f:0.f);
 if(id==1){
  /* Stable syncopated backbone, eight-bar call/response rather than one cell. */
  static const int slots[4]={0,6,10,14};
  const int degrees[4]={a,(a+1)%5,z,b%2?z:a};
  const float vel[4]={1,.64f,.84f,.57f};
  for(int i=0;i<4;i++)if(k==slots[i])note(s,ch[degrees[i]],1,(.075f+.04f*density)*vel[i]*detail*arc,.42f+.055f*i,0);
  if(k==0&&bar%4==0)signature_bed(s,ch,.038f);
  if((k==4||k==12))note(s,65,1,.011f*detail,.5f,0);
 }else if(id==2){
  if(k==0)orc_note(s->orchestra,11,s->plan.bass[b],.30f*arc,.47f,beat*7,s->seed);
  if(k==8)orc_note(s->orchestra,11,48,.21f,.49f,beat*6,s->seed);
  if(k==2||k==10)orc_note(s->orchestra,11,ch[k==2?a:z],(k==2?.34f:.28f)*detail*arc,.54f,beat*6,s->seed);
  /* Fixed low-key answering note, only in the second half of the phrase. */
  if(b>=4&&b%2==0&&k==14&&density>.25f)orc_note(s->orchestra,11,ch[(z+1)%5],.13f*detail,.55f,beat*5,s->seed);
  if(k==0&&bar%4==0){orc_note_held(s->orchestra,2,41,.08f,.58f,beat*18,s->seed);orc_note_held(s->orchestra,1,ch[2],.065f,.45f,beat*18,s->seed);}
 }else if(id==3){
  if(bar%4==0){
   if(k==0){orc_note_held(s->orchestra,2,s->plan.bass[b],.36f,.59f,beat*18,s->seed);orc_note_held(s->orchestra,2,48,.21f,.63f,beat*18,s->seed+1);}
   if(k==2){orc_note_held(s->orchestra,1,ch[1],.28f,.47f,beat*18,s->seed);orc_note_held(s->orchestra,1,ch[2],.19f,.52f,beat*18,s->seed+1);}
   if(k==4){orc_note_held(s->orchestra,0,ch[3],.23f,.28f,beat*18,s->seed);orc_note_held(s->orchestra,0,ch[4],.16f,.36f,beat*18,s->seed+1);}
   if(k==6){orc_note_held(s->orchestra,5,53,.23f,.63f,beat*18,s->seed);orc_note_held(s->orchestra,6,ch[1]-12,.15f,.5f,beat*18,s->seed);}
  }
  if(k%2==0&&detail>.005f){
   int i=k/2;int low=i==0?s->plan.bass[b]:i==4?41:i%2?48:ch[(b+i/2)%3]-12;
   orc_note(s->orchestra,3,low,.23f*(k%4==0?1.f:.73f)*detail*arc,.59f,beat*.76,s->seed);
   if(k==0||k==8)orc_note(s->orchestra,4,ch[k==0?a:z],.10f*detail,.30f,beat*.8,s->seed);
  }
  if(k==0||k==8)orc_note(s->orchestra,9,k==0?41:48,(k==0?.25f:.15f)*detail,.52f,beat*2,s->seed);
  if(k==6||k==14)orc_note(s->orchestra,8,ch[k==6?a:z],.10f*detail,.42f,beat*4,s->seed);
 }else if(id==4){
  if(k==0){int v[4]={ch[0],ch[1],ch[2],ch[3]};choir_chord(s->choir,v,beat*6);}
  if(bar%4==0&&k==0){orc_note_held(s->orchestra,2,s->plan.bass[b],.19f,.60f,beat*18,s->seed);orc_note_held(s->orchestra,1,ch[1],.11f,.46f,beat*18,s->seed);}
  if((k==2||k==10)&&density>.1f)orc_note(s->orchestra,8,ch[k==2?a:z],.13f*detail*arc,.47f,beat*4,s->seed);
  if(k==0||k==8)orc_note(s->orchestra,10,36,.065f*detail,.5f,beat*2,s->seed);
 }else if(id==5){
  /* Ambre: voiced tine chords, a composed relaxed backbeat and piano answers. */
  static const int late[4]={7,6,8,7};
  if(k==0||k==late[b%4]){
   float v=(k==0?.066f:.052f)*detail*arc;
   for(int j=1;j<4;j++)note(s,ch[j],6,v,.40f+.08f*j,j*.0035f);
  }
  if(k==12)note(s,ch[z],6,.032f*detail,.54f,0);
  if((k==4||k==12))note(s,60,7,.017f*detail,.5f,0);
  if(b>=4&&k==10)orc_note(s->orchestra,11,ch[a],.18f*detail,.52f,beat*3,s->seed);
  if(k==0&&bar%4==0)signature_bed(s,ch,.023f);
 }else if(id==6){
  /* Canopee: resonant wood in a two-part interlocking eight-bar phrase. */
  static const int slots[4]={0,5,8,12};int degree[4]={a,(a+1)%5,z,(z+2)%5};
  for(int j=0;j<4;j++)if(k==slots[j])note(s,ch[degree[j]],7,(j==0?.073f:.048f)*detail*arc,.37f+.07f*j,0);
  if(k==10&&(b%2==1))orc_note(s->orchestra,8,ch[z]+(z<2?12:0),.16f*detail,.55f,beat*4,s->seed);
  if(k==0&&bar%4==0){orc_note_held(s->orchestra,2,s->plan.bass[b],.15f,.60f,beat*18,s->seed);signature_bed(s,ch,.018f);}
  if(k==0||k==8)orc_note(s->orchestra,10,36,.075f*detail,.5f,beat*2,s->seed);
 }else if(id==7){
  /* Meridien: wide sustained chords and clear offbeats; no club build/drop. */
  if(k==2||k==10){for(int j=1;j<4;j++)note(s,ch[j],6,(k==2?.046f:.039f)*detail*arc,.38f+.09f*j,j*.002f);}
  if(k==6||k==14)note(s,ch[k==6?a:z]+(b>=4&&a<2?12:0),1,.046f*detail,.55f,0);
  if(k==4||k==12)note(s,65,7,.018f*detail,.5f,0);
  if(k==0&&bar%4==0)signature_bed(s,ch,.035f);
 }
 s->signatureEvents++;
}
