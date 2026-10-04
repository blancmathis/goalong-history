#ifndef ONDE_SONAR_PLANNER_H
#define ONDE_SONAR_PLANNER_H
#include "PhrasePlanner.h"
#ifdef __cplusplus
extern "C" {
#endif
/* One original bass-led Focus score (15) in a minimal deep-techno style.
 * Eight-bar phrases, harmony every 32 bars over a fixed G pedal, 128-bar
 * chapters. Deterministic and bounded; not a clinical protocol. */
int onde_sonar_plan(int style, uint64_t seed, uint64_t phrase, float evolution, OndePhrasePlan *out);
#ifdef __cplusplus
}
#endif
#endif
