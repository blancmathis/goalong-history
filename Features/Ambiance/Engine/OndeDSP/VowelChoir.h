#ifndef ONDE_VOWEL_CHOIR_H
#define ONDE_VOWEL_CHOIR_H
#include <stdint.h>
typedef struct VowelChoir VowelChoir;
/* Original vowel-like synthesis; not recordings or an imitation of a singer.
   Allocation/table design before playback. Rendering is allocation/lock free. */
VowelChoir *choir_create(double sample_rate);
void choir_destroy(VowelChoir *c);
void choir_chord(VowelChoir *c,const int midi[4],double transition_seconds);
void choir_frame(VowelChoir *c,float vowel,float *left,float *right);
int choir_voices(const VowelChoir *c);
#endif
