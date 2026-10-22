#pragma once
#include <stdint.h>
#include <stddef.h>
typedef struct Mobile Mobile;
Mobile *rh_create(const char *,const char *,const char *,const char *,char *,size_t);
int32_t rh_step(Mobile *,uint32_t,int32_t,uint16_t,uint16_t);
const uint8_t *rh_screen(const Mobile *,uint32_t,size_t *);
size_t rh_audio(Mobile *,int16_t *,size_t);
const char *rh_error(const Mobile *);
const char *rh_keyboard(Mobile *);
void rh_answer(Mobile *,const char *,uint32_t);
void rh_destroy(Mobile *);
void rh_note(const char *);
void rh_full_drawing(Mobile *,int32_t);
uint64_t rh_video_generation(const Mobile *);

static inline double rh_next_frame_deadline(double previous,double now,double period) {
    double deadline=previous+period;
    return now-deadline>0.25?now:deadline;
}
