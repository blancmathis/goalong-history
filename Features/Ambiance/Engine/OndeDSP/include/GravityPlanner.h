#ifndef ONDE_GRAVITY_PLANNER_H
#define ONDE_GRAVITY_PLANNER_H
#include "PhrasePlanner.h"
#ifdef __cplusplus
extern "C" {
#endif
/* One original bass-led Focus score (13). Eight-bar phrases, harmony every
 * 32 bars over a fixed F pedal, 128-bar chapters. Deterministic and bounded;
 * a finite authored vocabulary, not a clinical protocol or a no-repeat claim. */
int onde_gravity_plan(int style, uint64_t seed, uint64_t phrase, float evolution, OndePhrasePlan *out);
#ifdef __cplusplus
}
#endif
#endif
