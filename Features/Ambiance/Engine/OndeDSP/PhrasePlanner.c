/* Authored long-form grammar. MIT. No music, lyrics or learned parameters copied
   from another artist. Musical choices are not clinical optimization scores. */
#include "PhrasePlanner.h"
#include <math.h>
#include <string.h>
static uint64_t mix(uint64_t x){x+=UINT64_C(0x9e3779b97f4a7c15);x=(x^(x>>30))*UINT64_C(0xbf58476d1ce4e5b9);x=(x^(x>>27))*UINT64_C(0x94d049bb133111eb);return x^(x>>31);}
/* Six common-tone voicings per style; no random chromatic modulation. */
static const int chords[7][6][5]={
 {{53,60,63,67,72},{53,60,65,68,72},{53,58,63,68,72},{53,60,63,68,75},{53,58,65,68,72},{53,60,63,67,70}},
 {{53,57,60,65,67},{53,58,60,65,69},{53,57,62,65,69},{53,55,60,65,69},{53,57,60,64,69},{53,58,62,65,67}},
 {{53,60,65,67,72},{53,60,64,67,72},{53,58,65,67,72},{53,60,65,69,72},{53,57,64,67,72},{53,58,62,65,72}},
 {{53,60,65,69,72},{53,60,65,67,72},{53,58,65,69,72},{53,60,64,69,72},{53,57,64,67,72},{53,58,62,65,72}},
 {{53,57,60,64,67},{53,57,62,65,69},{53,58,60,65,69},{53,55,60,64,69},{53,57,60,64,69},{53,58,62,65,67}},
 {{53,60,65,67,72},{53,58,62,65,72},{53,57,60,65,69},{53,60,64,67,72},{53,58,65,69,72},{53,57,62,65,69}},
 {{53,60,63,67,72},{53,60,65,68,72},{53,58,63,68,72},{53,60,63,68,75},{53,58,65,68,72},{53,60,63,67,70}}
};
/* Each row is an eight-bar question/answer, two landmarks per bar.
   Repetition within a phrase makes it legible; the response is not a new solo. */
static const int themes[7][4][16]={
 {{0,2,1,2,0,3,2,1,0,2,3,2,1,3,2,0},{0,1,2,1,0,2,3,2,0,1,2,3,2,1,3,0},{1,2,1,3,2,1,0,2,1,3,2,3,1,2,1,0},{0,3,2,1,0,2,1,3,0,2,3,1,2,3,1,0}},
 {{1,2,4,2,1,3,2,1,1,2,3,4,2,3,2,1},{1,3,2,1,2,4,3,2,1,2,4,3,2,1,2,0},{2,3,4,3,2,1,2,3,2,4,3,2,1,3,2,1},{1,2,3,2,1,4,3,2,2,3,2,1,2,4,2,1}},
 {{0,1,2,1,0,2,3,2,0,1,3,2,1,3,2,0},{0,2,1,2,0,1,2,3,0,2,3,2,1,2,1,0},{1,2,3,2,1,0,2,1,1,3,2,3,2,1,2,0},{0,1,3,1,0,2,3,2,1,2,3,1,2,3,2,0}},
 {{1,2,1,3,2,3,2,1,1,3,2,3,1,2,3,1},{1,3,2,1,2,3,1,2,1,2,3,2,1,3,2,1},{2,3,2,1,2,1,3,2,1,2,3,1,2,3,2,1},{1,2,3,2,1,3,2,1,2,3,1,2,3,2,1,0}},
 {{1,2,3,2,1,4,3,2,1,3,4,3,2,1,2,1},{2,3,2,4,3,1,2,3,2,4,3,2,1,3,2,1},{1,3,2,1,2,3,4,2,1,2,4,3,2,3,2,1},{1,2,4,3,2,1,3,2,2,3,4,2,1,3,2,1}},
 {{0,2,1,3,2,1,0,2,1,3,2,4,2,3,1,0},{1,2,3,2,0,1,2,3,1,2,4,3,2,1,2,0},{0,1,2,4,2,3,1,2,0,2,3,4,3,2,1,0},{0,2,3,1,2,4,3,2,1,3,2,1,2,3,1,0}},
 {{0,2,1,2,0,3,1,2,0,2,3,1,2,3,1,0},{0,1,2,3,0,2,1,3,0,1,3,2,1,2,3,0},{1,2,0,2,1,3,2,0,1,2,3,2,0,2,1,0},{0,2,3,2,0,1,2,3,1,2,3,1,0,2,1,0}}
};
static const int routes[4][8]={{0,1,0,2,3,1,4,0},{0,2,1,3,0,4,5,1},{0,3,1,0,5,2,4,0},{0,1,4,2,0,5,3,1}};
static const float orchestration[6][7]={
 {1,.82f,.70f,.66f,.87f,.85f,1}, {.92f,1,.82f,.72f,1,.88f,.94f},
 {1.04f,.72f,1,.87f,.86f,.80f,.97f},{.96f,.88f,.84f,1,.95f,.90f,1.03f},
 {1,.94f,.90f,.74f,.90f,1,.94f},{1.02f,.82f,.92f,.87f,.97f,.85f,1}
};
int onde_phrase_plan(int style,uint64_t seed,uint64_t phrase,float evolution,OndePhrasePlan*out){
 if(!out||style<1||style>7||!isfinite(evolution)||evolution<0||evolution>1)return 0;
 memset(out,0,sizeof(*out));out->phrase=phrase;out->chapter=phrase/8;
 uint64_t chapter=evolution>.001f?out->chapter:0;
 uint64_t h=mix(seed^mix(chapter)^((uint64_t)style<<32));
 int primary=(int)(h%4),local=(int)(phrase%8);
 /* A A' B A'' across eight-bar phrases; two layers, not note-wise roulette. */
 static const int form[8]={0,0,1,0,2,1,3,2};
 int variant=(primary+(evolution>.001f?form[local]:0))%4;
 int route=(int)((h>>8)%4);uint64_t chordStep=evolution>.001f?phrase/2:0;
 int harmony=evolution>.001f?routes[route][chordStep%8]:0;
 if(phrase==0)harmony=0;
 memcpy(out->chord,chords[style-1][harmony],sizeof(out->chord));
 memcpy(out->melody,themes[style-1][variant],sizeof(out->melody));
 out->variant=variant;out->harmony=harmony;out->section=(int)((h>>16)%6);
 /* Lower inversions change at complete 16-bar boundaries, not every beat. */
 int bassRoot=(chordStep%4==0?41:out->chord[(chordStep+(h>>24))%2]-12);
 if(bassRoot>48)bassRoot-=12;
 for(int i=0;i<8;i++)out->bass[i]=i%4==0?bassRoot:i%2==0?53:48;
 for(int i=0;i<7;i++)out->levels[i]=1+(orchestration[out->section][i]-1)*(.5f+.5f*evolution);
 uint64_t f=UINT64_C(1469598103934665603);
 for(int i=0;i<5;i++)f=(f^(uint64_t)out->chord[i])*UINT64_C(1099511628211);
 for(int i=0;i<16;i++)f=(f^(uint64_t)out->melody[i])*UINT64_C(1099511628211);
 for(int i=0;i<8;i++)f=(f^(uint64_t)out->bass[i])*UINT64_C(1099511628211);
 out->fingerprint=f;return 1;
}
