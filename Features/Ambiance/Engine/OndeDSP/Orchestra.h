#ifndef ONDE_ORCHESTRA_INTERNAL_H
#define ONDE_ORCHESTRA_INTERNAL_H
#include <stdint.h>
#include "include/OndeDSP.h"
typedef struct Orchestra Orchestra;
Orchestra *orc_create(double sample_rate);
void orc_destroy(Orchestra *o);
int orc_add(Orchestra *o,int instrument,int root,int rr,const float *left,const float *right,uint32_t frames,double source_rate);
int orc_add_shared(Orchestra *o,int instrument,int root,int rr,OndeSampleBuffer *buffer);
int orc_add_pcm16(Orchestra *o,int instrument,int root,int rr,const int16_t *pcm,uint32_t frames,double rate);
int orc_count(const Orchestra *o);
int orc_families(const Orchestra *o);
int orc_voices(const Orchestra *o);
uint64_t orc_events(const Orchestra *o);
int orc_note(Orchestra *o,int instrument,int midi,float velocity,float pan,double seconds,uint64_t seed);
int orc_note_held(Orchestra *o,int instrument,int midi,float velocity,float pan,double seconds,uint64_t seed);
int orc_note_legato(Orchestra *o,int instrument,int midi,float velocity,float pan,double seconds,double fade,uint64_t seed);
void orc_frame(Orchestra *o,const float levels[7],float warmth,float *left,float *right);
#endif
