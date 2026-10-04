/* Original Sonar grammar, MIT. Composition choices, not clinical protocols.
 * Same long-form rules as Gravity and Orbit (home every second harmony,
 * common tones, no leading tone), in G Aeolian with open, quartal voicings. */
#include "SonarPlanner.h"
#include <math.h>
#include <string.h>
static uint64_t hash64(uint64_t x) {
    x += UINT64_C(0x9e3779b97f4a7c15);
    x = (x ^ (x >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)) * UINT64_C(0x94d049bb133111eb);
    return x ^ (x >> 31);
}
/* Six voicings from G Aeolian (G A Bb C D Eb F) over a low G that never moves.
 * Stacked fourths and fifths keep the chords open rather than sweet; each
 * shares at least three tones with home, and F natural avoids a leading tone. */
static const int harmony[6][5] = {
    {55,62,65,70,72}, {55,62,65,69,72}, {55,60,65,70,72},
    {55,62,63,70,74}, {55,62,67,70,74}, {55,58,65,70,72}
};
/* Eight-bar gestures, two landmarks per bar. The score sounds seven of them:
 * four pings on beat four, three on the "and" of beat two, and an open bar.
 * Degrees index the chord; the low G is never a melody note. */
static const int theme[4][16] = {
    {4,3,3,3,4,2,2,4,3,3,3,4,2,1,1,0},
    {3,4,4,2,3,4,4,3,4,2,2,3,3,1,2,0},
    {4,2,2,3,4,3,3,2,4,2,2,3,1,2,2,0},
    {2,3,3,4,2,4,4,3,3,4,4,2,2,1,1,0}
};
/* Every second harmony is home. */
static const int journey[4][8] = {
    {0,2,0,1,0,5,0,3}, {0,1,0,4,0,2,0,5},
    {0,5,0,3,0,1,0,2}, {0,2,0,4,0,5,0,1}
};
/* Chapter balances: chords, pings, acid colour, acid level, sub harmonics,
 * ticks, reserved. Small tilts; no layer is ever removed. */
static const float balance[6][7] = {
    {1.00f,1.00f,1.00f,1.00f,1.00f,1.00f,1},
    {1.08f,0.90f,0.88f,1.04f,1.06f,0.92f,1},
    {0.94f,1.06f,1.14f,0.96f,0.96f,1.06f,1},
    {1.04f,0.92f,1.08f,1.04f,1.02f,1.10f,1},
    {1.10f,1.08f,0.92f,0.94f,1.04f,0.90f,1},
    {0.96f,0.96f,1.06f,1.00f,1.08f,1.00f,1}
};
int onde_sonar_plan(int style, uint64_t seed, uint64_t phrase, float evolution, OndePhrasePlan *out) {
    if (!out || style != 15 || !isfinite(evolution) || evolution < 0 || evolution > 1) return 0;
    memset(out, 0, sizeof(*out));
    out->phrase = phrase; out->chapter = phrase / 16;
    uint64_t chapter = evolution > .001f ? out->chapter : 0;
    uint64_t h = hash64(seed ^ hash64(chapter) ^ ((uint64_t)style << 40));
    static const int sentence[16] = {0,0,1,0, 0,2,1,0, 0,0,1,0, 3,2,1,0};
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
    /* The acid line's last sixteenth is F, leading back to G. In bars four and eight
       it reaches further: to B flat, C, D or the D below. */
    static const int turn[4] = {46, 48, 50, 38};
    for (int i = 0; i < 8; i++) out->bass[i] = 41;
    out->bass[3] = 46; out->bass[7] = turn[variant];
    for (int i = 0; i < 7; i++) out->levels[i] = 1.f + (balance[out->section][i] - 1.f) * (.5f + .5f * evolution);
    uint64_t f = UINT64_C(1469598103934665603);
    for (int i = 0; i < 5; i++) f = (f ^ (uint64_t)out->chord[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 16; i++) f = (f ^ (uint64_t)out->melody[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 8; i++) f = (f ^ (uint64_t)out->bass[i]) * UINT64_C(1099511628211);
    for (int i = 0; i < 7; i++) f = (f ^ (uint64_t)(out->levels[i] * 10000)) * UINT64_C(1099511628211);
    out->fingerprint = f; return 1;
}
