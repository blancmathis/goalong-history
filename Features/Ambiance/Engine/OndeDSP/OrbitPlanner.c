/* Original Orbit grammar, MIT. Composition choices, not clinical protocols.
 * Same long-form rules as Gravity (home every second harmony, common tones,
 * no leading tone), written in A Dorian instead of F minor. */
#include "OrbitPlanner.h"
#include <math.h>
#include <string.h>
static uint64_t hash64(uint64_t x) {
    x += UINT64_C(0x9e3779b97f4a7c15);
    x = (x ^ (x >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)) * UINT64_C(0x94d049bb133111eb);
    return x ^ (x >> 31);
}
/* Six voicings from A Dorian (A B C D E F# G) over a low A that never moves.
 * Each shares at least three tones with home; the raised sixth (F#) gives the
 * warm, open colour; G natural keeps the key free of a leading tone. */
static const int harmony[6][5] = {
    {57,60,64,67,71}, {57,60,64,66,71}, {57,62,64,67,71},
    {57,60,64,67,74}, {57,59,64,67,72}, {57,62,64,66,71}
};
/* Eight-bar gestures, two landmarks per bar. The score sounds seven of them:
 * four answers on the "and" of beat three, three calls on beat two, and an
 * open last bar. Degrees index the chord; the low A is never a melody note. */
static const int theme[4][16] = {
    {2,4,4,3,3,4,4,2,2,4,4,3,3,1,1,0},
    {3,4,4,2,2,4,4,3,3,4,4,2,2,1,2,0},
    {4,3,3,2,4,3,3,1,4,3,3,2,2,1,1,0},
    {2,3,3,4,2,3,3,1,2,3,3,4,4,2,2,0}
};
/* Every second harmony is home. */
static const int journey[4][8] = {
    {0,1,0,2,0,3,0,5}, {0,2,0,5,0,1,0,4},
    {0,3,0,1,0,5,0,2}, {0,5,0,4,0,2,0,1}
};
/* Chapter balances: chords, keys, bass-line colour, bass-line level, sub
 * harmonics, backbeat, reserved. Small tilts; no layer is ever removed. */
static const float balance[6][7] = {
    {1.00f,1.00f,1.00f,1.00f,1.00f,1.00f,1},
    {1.06f,0.88f,0.92f,1.04f,1.08f,0.92f,1},
    {0.94f,1.08f,1.12f,0.96f,0.96f,1.04f,1},
    {1.04f,0.94f,1.06f,1.04f,1.02f,1.08f,1},
    {1.08f,1.06f,0.92f,0.96f,1.04f,0.90f,1},
    {0.98f,0.96f,1.04f,1.00f,1.06f,1.00f,1}
};
int onde_orbit_plan(int style, uint64_t seed, uint64_t phrase, float evolution, OndePhrasePlan *out) {
    if (!out || style != 14 || !isfinite(evolution) || evolution < 0 || evolution > 1) return 0;
    memset(out, 0, sizeof(*out));
    out->phrase = phrase; out->chapter = phrase / 16;
    uint64_t chapter = evolution > .001f ? out->chapter : 0;
    uint64_t h = hash64(seed ^ hash64(chapter) ^ ((uint64_t)style << 40));
    static const int sentence[16] = {0,0,1,0, 0,2,1,0, 0,0,1,0, 3,2,1,0};
    /* The first chapter always states the home theme. */
    int primary = chapter == 0 ? 0 : (int)(h % 4);
    int variant = (primary + (evolution > .001f ? sentence[phrase % 16] : 0)) % 4;
    uint64_t change = evolution > .001f ? phrase / 4 : 0;
    int route = (int)((h >> 9) % 4);
    int chord = evolution > .001f ? journey[route][change % 8] : 0;
    if (phrase < 4) chord = 0;
    memcpy(out->chord, harmony[chord], sizeof(out->chord));
    memcpy(out->melody, theme[variant], sizeof(out->melody));
    out->variant = variant; out->harmony = chord;
    out->section = out->chapter == 0 || evolution <= .001f ? 0 : (int)((h >> 17) % 6);
    /* The offbeat bass holds A2. Only the last offbeat of bars four and eight
       steps down, to G, E or D, and returns on the next offbeat. */
    static const int turn[4] = {43, 40, 43, 38};
    for (int i = 0; i < 8; i++) out->bass[i] = 45;
    out->bass[3] = 43; out->bass[7] = turn[variant];
    for (int i = 0; i < 7; i++) out->levels[i] = 1.f + (balance[out->section][i] - 1.f) * (.5f + .5f * evolution);
    uint64_t f = UINT64_C(1469598103934665603);
    for (int i = 0; i < 5; i++) f = (f ^ (uint64_t)out->chord[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 16; i++) f = (f ^ (uint64_t)out->melody[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 8; i++) f = (f ^ (uint64_t)out->bass[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 7; i++) f = (f ^ (uint64_t)(out->levels[i] * 10000)) * UINT64_C(1099511628211);
    out->fingerprint = f; return 1;
}
