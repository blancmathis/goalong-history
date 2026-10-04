#include "PlaybackEnvelope.h"
#include <math.h>
static float bound(float value) { return fmaxf(0.f, fminf(1.f, value)); }
void onde_envelope_reset(OndePlaybackEnvelope *e, float value) {
    if (!e || !isfinite(value)) return;
    e->elapsed=0; e->duration=0; e->start=e->value=e->target=bound(value);
}
void onde_envelope_to(OndePlaybackEnvelope *e, float target, double seconds) {
    if (!e || !isfinite(target) || !isfinite(seconds) || seconds<0 || seconds>30) return;
    e->start=e->value; e->target=bound(target); e->elapsed=0; e->duration=seconds;
    if (seconds==0 || e->start==e->target) { e->value=e->target; e->elapsed=seconds; }
}
float onde_envelope_step(OndePlaybackEnvelope *e, double seconds) {
    if (!e) return 0;
    if (!isfinite(seconds) || seconds<0) return e->value;
    if (e->duration<=0 || e->elapsed>=e->duration) return e->value=e->target;
    e->elapsed=fmin(e->duration,e->elapsed+seconds);
    double x=e->elapsed/e->duration;
    double curve=x*x*(3.-2.*x);
    /* Squared S-curve: quiet first quarter, gentle arrival, zero endpoint slope.
       Falling envelopes use the unsquared curve for a prompt, smooth pause. */
    if (e->target>e->start) curve*=curve;
    e->value=(float)(e->start+(e->target-e->start)*curve);
    if (e->elapsed>=e->duration) e->value=e->target;
    return e->value;
}
float onde_envelope_progress(const OndePlaybackEnvelope *e) {
    return !e || e->duration<=0 ? 1.f : (float)fmin(1.,e->elapsed/e->duration);
}
