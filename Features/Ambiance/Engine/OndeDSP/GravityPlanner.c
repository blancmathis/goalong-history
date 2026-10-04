/* Original Gravity grammar, MIT. Composition choices, not clinical protocols.
 * Deliberately separate from the other Focus and Relax grammars so that their
 * plans, fingerprints and audio stay exactly as they were. */
#include "GravityPlanner.h"
#include <math.h>
#include <string.h>
static uint64_t hash64(uint64_t x) {
    x += UINT64_C(0x9e3779b97f4a7c15);
    x = (x ^ (x >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)) * UINT64_C(0x94d049bb133111eb);
    return x ^ (x >> 31);
}
/* Six voicings from one six-note set (F G Ab Bb C Eb). The low F never moves,
 * every voicing shares at least three tones with home, and there is no
 * leading tone: the key stays unambiguous without asking for a resolution. */
static const int harmony[6][5] = {
    {53,60,63,67,70}, {53,60,63,68,72}, {53,58,63,67,72},
    {53,60,65,67,72}, {53,58,63,68,70}, {53,60,63,67,72}
};
/* Eight-bar gestures, two landmarks per bar. The score sounds seven of them:
 * a lone opening note, then three two-note figures (rise, fall, fall to rest)
 * and an open last bar. Degrees index the chord; the low F is never a melody. */
static const int theme[4][16] = {
    {3,2,2,2,3,2,4,4,3,2,2,2,1,1,0,0},
    {2,3,3,3,2,3,4,4,2,3,3,3,2,2,0,0},
    {4,3,3,3,4,3,2,2,4,3,3,3,2,2,0,0},
    {3,2,4,4,3,2,2,2,2,2,3,3,1,1,0,0}
};
/* Every second harmony is home. Leaving and returning is the whole journey. */
static const int journey[4][8] = {
    {0,1,0,2,0,3,0,4}, {0,2,0,1,0,5,0,3},
    {0,3,0,4,0,1,0,2}, {0,5,0,2,0,4,0,1}
};
/* Chapter balances: pad, motif, bass-line colour, bass-line level, sub
 * harmonics, backbeat, reserved. Small tilts; no layer is ever removed. */
static const float balance[6][7] = {
    {1.00f,1.00f,1.00f,1.00f,1.00f,1.00f,1},
    {0.92f,0.80f,0.84f,1.00f,1.12f,0.90f,1},
    {1.08f,1.05f,1.16f,0.96f,0.95f,1.00f,1},
    {0.96f,0.90f,1.10f,1.06f,1.00f,1.10f,1},
    {1.10f,1.10f,0.90f,0.94f,1.05f,0.85f,1},
    {1.00f,0.94f,1.05f,1.00f,1.06f,1.00f,1}
};
int onde_gravity_plan(int style, uint64_t seed, uint64_t phrase, float evolution, OndePhrasePlan *out) {
    if (!out || style != 13 || !isfinite(evolution) || evolution < 0 || evolution > 1) return 0;
    memset(out, 0, sizeof(*out));
    out->phrase = phrase; out->chapter = phrase / 16;
    uint64_t chapter = evolution > .001f ? out->chapter : 0;
    uint64_t h = hash64(seed ^ hash64(chapter) ^ ((uint64_t)style << 40));
    /* A A' A B | A A' A C: statement, small answer, then a longer release.
       Selection happens at phrase boundaries only; nothing is drawn per note. */
    static const int sentence[16] = {0,0,1,0, 0,2,1,0, 0,0,1,0, 3,2,1,0};
    /* The first chapter always states the home theme; a seed chooses the
       harmonic route at once and the leading theme of every later chapter. */
    int primary = chapter == 0 ? 0 : (int)(h % 4);
    int variant = (primary + (evolution > .001f ? sentence[phrase % 16] : 0)) % 4;
    /* Upper voices move every four phrases (32 bars). The opening stays home. */
    uint64_t change = evolution > .001f ? phrase / 4 : 0;
    int route = (int)((h >> 9) % 4);
    int chord = evolution > .001f ? journey[route][change % 8] : 0;
    if (phrase < 4) chord = 0;
    memcpy(out->chord, harmony[chord], sizeof(out->chord));
    memcpy(out->melody, theme[variant], sizeof(out->melody));
    out->variant = variant; out->harmony = chord;
    out->section = out->chapter == 0 || evolution <= .001f ? 0 : (int)((h >> 17) % 6);
    /* The offbeat bass holds F2. Only the last pickup of bars four and eight
       steps away, to the flat seventh, the fifth or the fourth, and returns on
       the next beat. */
    static const int turn[4] = {39, 36, 39, 46};
    for (int i = 0; i < 8; i++) out->bass[i] = 41;
    out->bass[3] = 39; out->bass[7] = turn[variant];
    for (int i = 0; i < 7; i++) out->levels[i] = 1.f + (balance[out->section][i] - 1.f) * (.5f + .5f * evolution);
    uint64_t f = UINT64_C(1469598103934665603);
    for (int i = 0; i < 5; i++) f = (f ^ (uint64_t)out->chord[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 16; i++) f = (f ^ (uint64_t)out->melody[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 8; i++) f = (f ^ (uint64_t)out->bass[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 7; i++) f = (f ^ (uint64_t)(out->levels[i] * 10000)) * UINT64_C(1099511628211);
    out->fingerprint = f; return 1;
}
