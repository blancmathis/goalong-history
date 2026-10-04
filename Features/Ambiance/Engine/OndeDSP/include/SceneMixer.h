#ifndef ONDE_SCENE_MIXER_H
#define ONDE_SCENE_MIXER_H
#include "OndeDSP.h"
typedef struct OndeSceneMixer OndeSceneMixer;
/* One control thread, one render thread. Submit owns the core on success.
   Creating/loading/deleting a scene NEVER occurs in the render callback. */
OndeSceneMixer *onde_scene_mixer_create(double rate);
void onde_scene_mixer_destroy(OndeSceneMixer *m);
int onde_scene_mixer_submit(OndeSceneMixer *m,OndeDSP *core,double seconds);
void onde_scene_mixer_collect(OndeSceneMixer *m);
/* Arm a transport envelope. The rising clock waits for an active scene.
   Call on start/pause/resume, NEVER on routine volume/parameter changes. */
void onde_scene_mixer_playback(OndeSceneMixer *m,int playing,double seconds);
uint64_t onde_scene_mixer_entrance_frames(const OndeSceneMixer *m);
uint64_t onde_scene_mixer_entrance_intermediate(const OndeSceneMixer *m);
uint64_t onde_scene_mixer_entrance_serial(const OndeSceneMixer *m);
float onde_scene_mixer_entrance_first_gain(const OndeSceneMixer *m);
int onde_scene_mixer_entrance_pending(const OndeSceneMixer *m);
float onde_scene_mixer_entrance_gain(const OndeSceneMixer *m);
float onde_scene_mixer_entrance_progress(const OndeSceneMixer *m);
void onde_scene_mixer_gain(OndeSceneMixer *m,float gain);
void onde_scene_mixer_render(OndeSceneMixer *m,float *left,float *right,uint32_t frames);
/* Control thread only. Pointers stay alive until collect/submit/destroy. */
OndeDSP *onde_scene_mixer_visible(const OndeSceneMixer *m);
int onde_scene_mixer_state(const OndeSceneMixer *m); /* 0 idle, 1 waiting for bar, 2 crossfading */
int onde_scene_mixer_pending(const OndeSceneMixer *m);
float onde_scene_mixer_progress(const OndeSceneMixer *m);
float onde_scene_mixer_actual_gain(const OndeSceneMixer *m);
float onde_scene_mixer_peak(const OndeSceneMixer *m);
float onde_scene_mixer_rms(const OndeSceneMixer *m);
uint64_t onde_dsp_frames_to_bar(const OndeDSP *s); /* render thread only */
#endif
