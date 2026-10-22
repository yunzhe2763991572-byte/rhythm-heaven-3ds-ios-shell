/* Generic controller mapping and edge capture; no game content. */
#ifndef RH_CONTROLLER_INPUT_H
#define RH_CONTROLLER_INPUT_H
#include <stdint.h>
#include <stdbool.h>

enum {
    RH_A=1u<<0, RH_B=1u<<1, RH_SELECT=1u<<2, RH_START=1u<<3,
    RH_RIGHT=1u<<4, RH_LEFT=1u<<5, RH_UP=1u<<6, RH_DOWN=1u<<7,
    RH_R=1u<<8, RH_L=1u<<9, RH_X=1u<<10, RH_Y=1u<<11
};
typedef struct {
    bool bottom,right,left,top;
    bool dpadUp,dpadDown,dpadLeft,dpadRight;
    bool stickUp,stickDown,stickLeft,stickRight;
    bool shoulderLeft,shoulderRight,menu,options;
} RHControllerButtons;

/* Apple names the face elements by Xbox position. Preserve Nintendo positions,
 * just as the touch layout does: right=A, bottom=B, top=X, left=Y.
 * The left stick is an alternative digital D-pad in this rhythm-game host.
 * Read its system-provided directional isPressed values, without a second
 * analog deadzone. Opposing directions cancel after the two sources merge. */
static inline uint32_t rh_controller_mask(RHControllerButtons b) {
    uint32_t m=0;
    if(b.right)m|=RH_A; if(b.bottom)m|=RH_B;
    if(b.top)m|=RH_X; if(b.left)m|=RH_Y;
    bool up=b.dpadUp||b.stickUp, down=b.dpadDown||b.stickDown;
    bool left=b.dpadLeft||b.stickLeft, right=b.dpadRight||b.stickRight;
    if(up&&!down)m|=RH_UP; if(down&&!up)m|=RH_DOWN;
    if(left&&!right)m|=RH_LEFT; if(right&&!left)m|=RH_RIGHT;
    if(b.shoulderLeft)m|=RH_L; if(b.shoulderRight)m|=RH_R;
    if(b.menu)m|=RH_START; if(b.options)m|=RH_SELECT;
    return m;
}

typedef struct { uint32_t raw,held,latched,blocked; } RHControllerState;
static inline void rh_controller_update(RHControllerState *s,uint32_t raw,bool enabled) {
    s->raw=raw;
    if(!enabled) { s->blocked=raw;s->held=s->latched=0;return; }
    s->blocked&=raw;
    uint32_t held=raw&~s->blocked;
    s->latched|=held&~s->held;
    s->held=held;
}
/* A held key must be released before it can press again after pause, an
 * orientation change, a system dialog, or connecting a different controller. */
static inline void rh_controller_clear(RHControllerState *s) {
    s->blocked=s->raw;s->held=s->latched=0;
}
static inline uint32_t rh_controller_take(RHControllerState *s) {
    uint32_t keys=s->held|s->latched;s->latched=0;return keys;
}
#endif
