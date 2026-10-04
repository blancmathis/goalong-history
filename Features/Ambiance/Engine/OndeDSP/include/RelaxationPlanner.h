#ifndef ONDE_RELAXATION_PLANNER_H
#define ONDE_RELAXATION_PLANNER_H
#include "PhrasePlanner.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Five original scores (8..12). Eight-bar sentences; 96-bar chapters.
 * A finite authored vocabulary is developed continuously, not a no-repeat claim. */
int onde_relaxation_plan(int style, uint64_t seed, uint64_t phrase, float evolution, OndePhrasePlan *out);
#ifdef __cplusplus
}
#endif
#endif
