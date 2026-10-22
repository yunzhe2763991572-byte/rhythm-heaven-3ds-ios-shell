"""Compile the production portable input header and test chord/lifecycle behavior."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
TEST=r'''
#include <assert.h>
#include <stdio.h>
#include "ControllerInput.h"
static unsigned checks;
static void eq(uint32_t got,uint32_t expected) { assert(got==expected);checks++; }
int main(void) {
    // Face-button chords include A+B, all four together, and every release.
    for(unsigned chord=0;chord<16;chord++) {
        RHControllerButtons b={.right=!!(chord&1),.bottom=!!(chord&2),
            .top=!!(chord&4),.left=!!(chord&8)};
        eq(rh_controller_mask(b),(chord&3)|((chord&12)<<8));
    }
    // D-pad and stick can independently hold the same direction. Only
    // contradictions on the same axis cancel; diagonals remain available.
    for(unsigned d=0;d<16;d++)for(unsigned s=0;s<16;s++) {
        RHControllerButtons b={.dpadRight=!!(d&1),.dpadLeft=!!(d&2),
            .dpadUp=!!(d&4),.dpadDown=!!(d&8),.stickRight=!!(s&1),
            .stickLeft=!!(s&2),.stickUp=!!(s&4),.stickDown=!!(s&8)};
        unsigned directions=d|s;
        if((directions&3)==3)directions&=~3u;
        if((directions&12)==12)directions&=~12u;
        eq(rh_controller_mask(b),directions<<4);
    }
    eq(rh_controller_mask((RHControllerButtons){.shoulderLeft=true}),512);
    eq(rh_controller_mask((RHControllerButtons){.shoulderRight=true}),256);
    eq(rh_controller_mask((RHControllerButtons){.menu=true}),8);
    eq(rh_controller_mask((RHControllerButtons){.options=true}),4);

    RHControllerState p={0};
    rh_controller_update(&p,1,true);rh_controller_update(&p,0,true);
    eq(rh_controller_take(&p),1); // press and release between game frames
    eq(rh_controller_take(&p),0); // one-shot is consumed exactly once
    rh_controller_update(&p,3,true);eq(rh_controller_take(&p),3);
    rh_controller_update(&p,1,true);eq(rh_controller_take(&p),1);
    eq(rh_controller_take(&p),1); // held input is continuous, never auto-repeated
    uint32_t touch=1;
    eq(touch|rh_controller_take(&p),1);
    rh_controller_update(&p,0,true);eq(touch|rh_controller_take(&p),1);
    rh_controller_update(&p,1,true);touch=0;
    eq(touch|rh_controller_take(&p),1); // touch release cannot release a pad key
    // Pause, rotate, keyboard, and screen swap use this release barrier.
    rh_controller_clear(&p);eq(rh_controller_take(&p),0);
    rh_controller_update(&p,1,true);eq(rh_controller_take(&p),0);
    rh_controller_update(&p,3,true);eq(rh_controller_take(&p),2);
    rh_controller_update(&p,0,true);rh_controller_update(&p,1,true);
    eq(rh_controller_take(&p),1);
    // No key pressed in the background is queued for the next foreground.
    rh_controller_update(&p,2,false);eq(rh_controller_take(&p),0);
    rh_controller_update(&p,3,false);eq(rh_controller_take(&p),0);
    rh_controller_update(&p,3,true);eq(rh_controller_take(&p),0);
    rh_controller_update(&p,0,true);rh_controller_update(&p,3,true);
    eq(rh_controller_take(&p),3);
    // A disconnect removes only the physical source, preserving live touch.
    touch=2;p=(RHControllerState){0};eq(touch|rh_controller_take(&p),2);
    // A different controller cannot inherit a previous controller's edges.
    rh_controller_update(&p,3,true);rh_controller_clear(&p);
    eq(rh_controller_take(&p),0);
    rh_controller_update(&p,0,true);rh_controller_update(&p,2,true);
    eq(rh_controller_take(&p),2);
    printf("controller input: %u checks passed\n",checks);
    return 0;
}
'''

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--cc",default="clang")
    args=p.parse_args()
    with tempfile.TemporaryDirectory(prefix="rh3ds-controller-") as tmp:
        source=Path(tmp)/"test.c"
        binary=Path(tmp)/"test.exe"
        source.write_text(TEST,encoding="utf-8")
        subprocess.run([args.cc,"-std=c11","-Wall","-Wextra","-Werror","-O2",
            "-I",str(ROOT/"source/ios-host"),str(source),"-o",str(binary)],check=True)
        subprocess.run([str(binary)],check=True)

if __name__=="__main__":
    main()
