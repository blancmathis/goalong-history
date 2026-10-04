#ifndef ONDE_ORBIT_PLANNER_H
#define ONDE_ORBIT_PLANNER_H
#include "PhrasePlanner.h"
#ifdef __cplusplus
extern "C" {
#endif
/* One original bass-led Focus score (14), the warm sibling of Gravity.
 * Eight-bar phrases, harmony every 32 bars over a fixed A pedal, 128-bar
 * chapters. Deterministic and bounded; not a clinical protocol. */
int onde_orbit_plan(int style, uint64_t seed, uint64_t phrase, float evolution, OndePhrasePlan *out);
#ifdef __cplusplus
}
#endif
#endif
