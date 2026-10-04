#ifndef ONDE_DSP_H
#define ONDE_DSP_H
#include <stdint.h>
#include "PlaybackEnvelope.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Original hybrid engine, MIT. Optional verified CC0 acoustic note bank; no trained model weights.
   Allocation happens only in create/destroy. Render never allocates, blocks,
   accesses a file, or calls back into Swift. Controls use lock-free atomics.
   One render thread per instance. UI setters and stat readers may be concurrent. */
typedef struct OndeDSP OndeDSP;
typedef struct OndeSampleBuffer OndeSampleBuffer;
/* A scene retains immutable PCM. Caller releases its reference after addition.
   Create/add/release are non-render-thread operations. NULL release is safe. */
OndeSampleBuffer *onde_sample_buffer_create(const float *left,const float *right,uint32_t frames,double rate);
void onde_sample_buffer_release(OndeSampleBuffer *buffer);
uint32_t onde_sample_buffer_references(const OndeSampleBuffer *buffer);
int onde_dsp_add_shared_sample(OndeDSP *s,int instrument,int root,int rr,OndeSampleBuffer *buffer);
enum { ONDE_DENSITY, ONDE_BRIGHTNESS, ONDE_MOVEMENT, ONDE_SPACE,
       ONDE_TEXTURE, ONDE_PULSE, ONDE_EVOLUTION, ONDE_SETTLE_MINUTES,
       ONDE_GAIN, ONDE_BASS, ONDE_TEMPO, ONDE_STABILITY, ONDE_WARMTH, ONDE_CHARACTER, ONDE_DRIVE, ONDE_PUNCH, ONDE_ORCHESTRA, ONDE_STRINGS, ONDE_BRASS, ONDE_WOODS, ONDE_HARP, ONDE_OSTINATO, ONDE_PERCUSSION, ONDE_COMPOSITION, ONDE_VOCALS, ONDE_PIANO, ONDE_PARAM_COUNT };
OndeDSP *onde_dsp_create(double sample_rate, int mode, uint64_t seed);
void onde_dsp_destroy(OndeDSP *s);
/* Copies a verified note recording. Only allowed before the first render.
   Instrument IDs 0..11 and MIDI roots 0..127. Stereo, finite normalized PCM. */
int onde_dsp_add_sample(OndeDSP *s,int instrument,int root,int rr,const float *left,const float *right,uint32_t frames,double source_rate);
/* Goalong zero-copy PCM16: mapping must outlive this DSP. Prepare only. */
int onde_dsp_add_pcm16_sample(OndeDSP *s,int instrument,int root,int rr,const int16_t *pcm,uint32_t frames,double source_rate);
int onde_dsp_orchestra_samples(const OndeDSP *s);
int onde_dsp_orchestra_families(const OndeDSP *s);
int onde_dsp_orchestra_voices(const OndeDSP *s);
uint64_t onde_dsp_orchestra_events(const OndeDSP *s);
void onde_dsp_set(OndeDSP *s, int parameter, float value);
void onde_dsp_set_mode(OndeDSP *s, int mode);
void onde_dsp_set_seed(OndeDSP *s, uint64_t seed);
int onde_dsp_composition(const OndeDSP *s);
uint64_t onde_dsp_signature_events(const OndeDSP *s);
int onde_dsp_choir_voices(const OndeDSP *s);
void onde_dsp_render(OndeDSP *s, float *left, float *right, uint32_t frames);
uint64_t onde_dsp_phrase(const OndeDSP *s);
uint64_t onde_dsp_chapter(const OndeDSP *s);
uint64_t onde_dsp_plan_hash(const OndeDSP *s);
int onde_dsp_variant(const OndeDSP *s);
void onde_dsp_set_rhythm_weight(OndeDSP *s,float weight);
uint64_t onde_dsp_frames(const OndeDSP *s);
uint64_t onde_dsp_events(const OndeDSP *s);
float onde_dsp_peak(const OndeDSP *s);
float onde_dsp_rms(const OndeDSP *s);
float onde_dsp_gain(const OndeDSP *s);
uint64_t onde_dsp_note_events(const OndeDSP *s);
uint64_t onde_dsp_grain_events(const OndeDSP *s);
uint64_t onde_dsp_bars(const OndeDSP *s);
int onde_dsp_section(const OndeDSP *s);
int onde_dsp_harmony(const OndeDSP *s);
int onde_dsp_voices(const OndeDSP *s);
float onde_dsp_bpm(const OndeDSP *s);

uint64_t onde_dsp_beats(const OndeDSP *s);
uint64_t onde_dsp_ticks(const OndeDSP *s);
uint64_t onde_dsp_min_beat_gap(const OndeDSP *s);
uint64_t onde_dsp_max_beat_gap(const OndeDSP *s);
#ifdef __cplusplus
}
#endif
#include "PhrasePlanner.h"
#include "RelaxationPlanner.h"
#include "GravityPlanner.h"
#include "SceneMixer.h"
#endif
