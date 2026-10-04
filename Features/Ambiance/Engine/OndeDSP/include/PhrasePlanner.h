#ifndef ONDE_PHRASE_PLANNER_H
#define ONDE_PHRASE_PLANNER_H
#include <stdint.h>
/* One plan covers eight measures. All choices are deterministic and bounded;
   a new chapter changes orchestration, not the identity or tempo. */
typedef struct {
    int chord[5], melody[16], bass[8];
    int variant, harmony, section;
    uint64_t chapter, phrase, fingerprint;
    float levels[7];
} OndePhrasePlan;
int onde_phrase_plan(int style, uint64_t seed, uint64_t phrase, float evolution, OndePhrasePlan *out);
#endif
