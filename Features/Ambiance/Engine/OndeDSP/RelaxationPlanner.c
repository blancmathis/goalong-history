/* Original relaxation grammar, MIT. Composition choices, not clinical protocols.
 * Deliberately separate from the Focus grammar to preserve existing music. */
#include "RelaxationPlanner.h"
#include <math.h>
#include <string.h>
static uint64_t hash64(uint64_t x) {
    x += UINT64_C(0x9e3779b97f4a7c15);
    x = (x ^ (x >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)) * UINT64_C(0x94d049bb133111eb);
    return x ^ (x >> 31);
}
/* Common tones keep harmonic changes gentle. No chromatic note roulette.
 * Piano, chamber, choir and resonator voices each have their own register. */
static const int harmony[5][6][5] = {
 {{53,60,65,69,72},{53,60,65,67,72},{53,58,65,69,72},{53,60,64,69,72},{53,57,60,65,72},{53,58,62,65,72}},
 {{53,57,60,65,69},{53,57,62,65,69},{53,58,60,65,69},{53,55,60,65,67},{53,57,60,64,69},{53,58,62,65,69}},
 {{53,60,65,69,72},{53,60,65,67,72},{53,58,62,65,72},{53,57,60,65,69},{53,60,64,67,72},{53,58,60,65,72}},
 {{53,60,65,67,72},{53,60,65,69,72},{53,58,65,69,72},{53,60,64,67,72},{53,57,60,65,72},{53,58,62,65,72}},
 {{53,60,65,67,72},{53,57,60,65,69},{53,58,62,65,72},{53,60,65,69,72},{53,55,60,65,67},{53,58,60,65,72}}
};
/* Eight-bar gestures: landmarks, not a demand to play on every beat.
 * The scheduler below each score determines the rests and instrumentation. */
static const int theme[5][4][16] = {
 {{0,2,2,3,1,2,2,1,0,2,3,2,1,2,1,0},{0,1,2,1,0,3,2,1,0,2,3,1,2,1,2,0},{1,2,1,3,2,1,0,1,1,2,3,2,1,2,1,0},{0,2,1,2,3,2,1,0,0,3,2,3,2,1,2,0}},
 {{1,2,3,2,1,4,3,1,2,3,2,4,3,2,1,0},{1,3,2,1,2,4,3,2,1,2,4,3,2,1,2,0},{2,3,4,3,2,1,3,2,2,4,3,2,1,2,3,1},{1,2,4,2,3,2,1,2,1,3,4,2,3,1,2,0}},
 {{0,1,2,1,0,2,3,2,1,2,3,1,2,1,2,0},{0,2,1,2,0,1,3,1,1,2,3,2,1,3,2,0},{1,2,3,2,1,0,2,1,1,3,2,3,2,1,2,0},{0,1,3,1,2,3,2,1,0,2,3,2,1,2,1,0}},
 {{1,2,1,3,2,1,2,1,1,3,2,3,1,2,1,0},{1,3,2,1,2,3,1,2,1,2,3,2,1,3,2,0},{2,3,2,1,2,1,3,2,1,2,3,1,2,3,1,0},{1,2,3,2,1,3,2,1,2,3,1,2,3,2,1,0}},
 {{0,2,1,3,2,1,0,2,1,3,2,4,2,3,1,0},{1,2,3,2,0,1,2,3,1,2,4,3,2,1,2,0},{0,1,2,4,2,3,1,2,0,2,3,4,3,2,1,0},{0,2,3,1,2,4,3,2,1,3,2,1,2,3,1,0}}
};
static const int journey[4][12] = {
 {0,1,0,2,1,3,0,4,1,2,5,0}, {0,2,1,0,3,1,4,0,2,5,1,0},
 {0,1,4,0,2,1,3,0,5,2,1,0}, {0,3,1,0,4,1,2,0,1,5,2,0}
};
int onde_relaxation_plan(int style,uint64_t seed,uint64_t phrase,float evolution,OndePhrasePlan *out) {
    if (!out || style < 8 || style > 12 || !isfinite(evolution) || evolution < 0 || evolution > 1) return 0;
    memset(out,0,sizeof(*out));
    out->phrase=phrase; out->chapter=phrase/12;
    uint64_t chapter=evolution>.001f?out->chapter:0;
    uint64_t h=hash64(seed ^ hash64(chapter) ^ ((uint64_t)style<<40));
    /* Three sentences: statement, related answer, release. Selection is at
       phrase boundaries only; never skip a note through a random draw. */
    static const int sentence[12]={0,0,1,0,2,1,0,1,3,2,1,0};
    int variant=((int)(h%4)+(evolution>.001f?sentence[phrase%12]:0))%4;
    uint64_t change=evolution>.001f?phrase/2:0;
    int route=(int)((h>>9)%4);
    int chord=evolution>.001f?journey[route][change%12]:0;
    if (phrase==0) chord=0;
    memcpy(out->chord,harmony[style-8][chord],sizeof(out->chord));
    memcpy(out->melody,theme[style-8][variant],sizeof(out->melody));
    out->variant=variant;out->harmony=chord;out->section=(int)((h>>17)%6);
    for(int i=0;i<8;i++) out->bass[i]=(i<4?41:48);
    for(int i=0;i<7;i++) {
        int shift=(int)((h>>(i*5))&7)-3;
        out->levels[i]=1.f+shift*.018f*evolution;
    }
    uint64_t f=UINT64_C(1469598103934665603);
    for(int i=0;i<5;i++) f=(f^(uint64_t)out->chord[i])*UINT64_C(1099511628211);
    for(int i=0;i<16;i++) f=(f^(uint64_t)out->melody[i])*UINT64_C(1099511628211);
    for(int i=0;i<7;i++) f=(f^(uint64_t)(out->levels[i]*10000))*UINT64_C(1099511628211);
    out->fingerprint=f;return 1;
}
