#ifndef ONDE_PLAYBACK_ENVELOPE_H
#define ONDE_PLAYBACK_ENVELOPE_H
/* Transport fade, independent of user volume and musical scene transitions.
   Pure, allocation-free state; the caller supplies elapsed AUDIO time. */
typedef struct OndePlaybackEnvelope {
    double elapsed, duration;
    float start, value, target;
} OndePlaybackEnvelope;
void onde_envelope_reset(OndePlaybackEnvelope *e, float value);
void onde_envelope_to(OndePlaybackEnvelope *e, float target, double seconds);
float onde_envelope_step(OndePlaybackEnvelope *e, double seconds);
float onde_envelope_progress(const OndePlaybackEnvelope *e);
#endif
