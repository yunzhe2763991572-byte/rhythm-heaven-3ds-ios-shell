#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <QuartzCore/QuartzCore.h>
#import <GameController/GameController.h>
#import "Mobile.h"
#include "ControllerInput.h"
#include <string.h>
#include <stdatomic.h>

static const double FramePeriod = 4481136.0 / 268111856.0;
static const size_t RingFrames = 65536;

@interface Sound : NSObject {
    AudioQueueRef queue;
    NSLock *lock;
    int16_t ring[65536 * 2];
    uint64_t readAt, writeAt;
    uint64_t underrunFrames;
}
- (void)push:(const int16_t *)samples frames:(size_t)frames;
- (void)fill:(AudioQueueBufferRef)buffer;
- (void)pause:(BOOL)paused;
- (NSString *)diagnostics;
@end
static void AudioCallback(void *user, AudioQueueRef q, AudioQueueBufferRef buffer) {
    [(__bridge Sound *)user fill:buffer];
    AudioQueueEnqueueBuffer(q,buffer,0,NULL);
}
@implementation Sound
- (instancetype)init {
    if ((self=[super init])) {
        lock=[NSLock new];
        NSError *error=nil;
        AVAudioSession *session=[AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:&error];
        [session setPreferredIOBufferDuration:0.005 error:nil];
        [session setActive:YES error:&error];
        AudioStreamBasicDescription format={0};
        format.mSampleRate=32728.498;
        format.mFormatID=kAudioFormatLinearPCM;
        format.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger|kLinearPCMFormatFlagIsPacked;
        format.mBytesPerPacket=4; format.mFramesPerPacket=1;
        format.mBytesPerFrame=4; format.mChannelsPerFrame=2; format.mBitsPerChannel=16;
        OSStatus result=AudioQueueNewOutput(&format,AudioCallback,(__bridge void *)self,NULL,NULL,0,&queue);
        if (result==noErr) {
            for (int i=0;i<3;i++) {
                AudioQueueBufferRef buffer=NULL;
                if (AudioQueueAllocateBuffer(queue,256*4,&buffer)==noErr) {
                    [self fill:buffer]; AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
                }
            }
            AudioQueueStart(queue,NULL);
        } else { NSLog(@"AudioQueue failed: %d",(int)result); }
    }
    return self;
}
- (void)push:(const int16_t *)samples frames:(size_t)frames {
    [lock lock];
    // Bound buffered sound to about 125 ms rather than accumulating latency.
    if (writeAt-readAt+frames>4096) readAt=writeAt;
    for (size_t i=0;i<frames;i++) {
        size_t at=(writeAt++%RingFrames)*2;
        ring[at]=samples[i*2]; ring[at+1]=samples[i*2+1];
    }
    [lock unlock];
}
- (void)fill:(AudioQueueBufferRef)buffer {
    int16_t *out=buffer->mAudioData;
    size_t frames=buffer->mAudioDataBytesCapacity/4;
    [lock lock];
    for (size_t i=0;i<frames;i++) {
        if (readAt<writeAt) {
            size_t at=(readAt++%RingFrames)*2;
            out[i*2]=ring[at]; out[i*2+1]=ring[at+1];
        } else { out[i*2]=0; out[i*2+1]=0; underrunFrames++; }
    }
    [lock unlock];
    buffer->mAudioDataByteSize=(UInt32)(frames*4);
}
- (void)pause:(BOOL)paused {
    if (!queue) return;
    if (paused) AudioQueuePause(queue); else AudioQueueStart(queue,NULL);
    [lock lock]; readAt=writeAt; [lock unlock];
}
- (NSString *)diagnostics {
    [lock lock];
    uint64_t empty=underrunFrames,buffered=writeAt-readAt;
    [lock unlock];
    return [NSString stringWithFormat:@"audio missing %llu sample-frames, buffered %llu",(unsigned long long)empty,(unsigned long long)buffered];
}
- (void)dealloc { if (queue) AudioQueueDispose(queue,true); }
@end

// Keep the compact selector easy to tap in either orientation without
// extending into the adjacent gameplay controls.
@interface ControlStyleButton : UIButton
@end
@implementation ControlStyleButton
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if(self.bounds.size.height<44) return CGRectContainsPoint(CGRectInset(self.bounds,-6,-(44-self.bounds.size.height)/2),point);
    return [super pointInside:point withEvent:event];
}
@end

@interface TouchScreen : UIImageView
@property(copy) void (^touchChanged)(BOOL,CGPoint);
@end
@implementation TouchScreen
- (void)track:(NSSet<UITouch *> *)touches down:(BOOL)down {
    UITouch *touch=touches.anyObject;
    if (touch && self.touchChanged) self.touchChanged(down,[touch locationInView:self]);
}
- (void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e { [self track:t down:YES]; }
- (void)touchesMoved:(NSSet *)t withEvent:(UIEvent *)e { [self track:t down:YES]; }
- (void)touchesEnded:(NSSet *)t withEvent:(UIEvent *)e { [self track:t down:NO]; }
- (void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e { [self track:t down:NO]; }
@end

static UIImage *Image(const uint8_t *bytes,size_t count,size_t width) {
    if (!bytes || count!=width*240*4) return nil;
    NSData *data=[NSData dataWithBytes:bytes length:count];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGImageRef image=CGImageCreate(width,240,8,32,width*4,space,kCGBitmapByteOrder32Big|kCGImageAlphaLast,
        provider,NULL,false,kCGRenderingIntentDefault);
    UIImage *result=image?[UIImage imageWithCGImage:image]:nil;
    if (image) CGImageRelease(image);
    CGColorSpaceRelease(space); CGDataProviderRelease(provider);
    return result;
}

@interface Game : UIViewController {
    Mobile *machine;
    dispatch_queue_t worker;
    CADisplayLink *display;
    UIImageView *top;
    TouchScreen *bottom;
    UILabel *status;
    NSMutableArray<UIButton *> *buttons;
    UIButton *pauseButton;
    UIButton *qualityButton;
    UIButton *screenSwapButton;
    UIButton *controlStyleButton;
    BOOL dualAB;
    BOOL screensSwapped,wasRunningBeforeBackground;
    Sound *sound;
    _Atomic(BOOL) paused,keyboardActive,failed;
    BOOL touchDown,touchLatched;
    NSLock *inputLock,*videoLock;
    UIImage *pendingUpper,*pendingLower;
    uint64_t pendingGeneration,totalLogicFrames,seenLogicFrames;
    uint64_t copiedGeneration;
    uint32_t held,latched;
    GCController *activeController;
    RHControllerState controllerInput;
    CGPoint touchPoint;
    double lastFrameTime;
    double nextEmulationTime;
    int metricFrames;
    BOOL fullDrawing;
    double fpsWindowStart;
    uint64_t shownVideoGeneration;
    unsigned logicFrames,visualFrames;
}
@end
@implementation Game
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.blackColor;
    self.view.multipleTouchEnabled=YES;
    dualAB=[[NSUserDefaults standardUserDefaults] boolForKey:@"rh3ds.dualABControls"];
    inputLock=[NSLock new];videoLock=[NSLock new];
    dispatch_queue_attr_t priority=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0);
    worker=dispatch_queue_create("org.rhythmheaven.3ds.runtime",priority);
    top=[UIImageView new]; bottom=[TouchScreen new];
    for (UIImageView *view in @[top,bottom]) {
        view.contentMode=UIViewContentModeScaleAspectFit; view.backgroundColor=UIColor.blackColor;
        [self.view addSubview:view];
    }
    bottom.userInteractionEnabled=YES;
    __weak Game *weakSelf=self;
    bottom.touchChanged=^(BOOL down,CGPoint point) { [weakSelf touch:down point:point]; };
    status=[UILabel new]; status.text=@"正在启动 3DS 实验版…";
    status.textColor=UIColor.whiteColor; status.numberOfLines=0; status.textAlignment=NSTextAlignmentCenter;
    [self.view addSubview:status];
    buttons=[NSMutableArray new];
    NSArray *names=@[@"↑",@"←",@"↓",@"→",@"A",@"B",@"X",@"Y",@"START",@"SELECT",@"L",@"R"];
    uint32_t bits[]={1<<6,1<<5,1<<7,1<<4,1<<0,1<<1,1<<10,1<<11,1<<3,1<<2,1<<9,1<<8};
    for (NSUInteger i=0;i<names.count;i++) {
        UIButton *button=[UIButton buttonWithType:UIButtonTypeCustom];
        [button setTitle:names[i] forState:UIControlStateNormal]; button.tag=bits[i];
        button.backgroundColor=[UIColor colorWithWhite:0.16 alpha:1];
        button.layer.cornerRadius=14; button.layer.borderWidth=1; button.layer.borderColor=UIColor.darkGrayColor.CGColor;
        button.titleLabel.font=[UIFont boldSystemFontOfSize:i==4?36:(i<4?28:(i<8?23:13))];
        button.multipleTouchEnabled=YES; button.exclusiveTouch=NO;
        [button addTarget:self action:@selector(down:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(up:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
        [self.view addSubview:button]; [buttons addObject:button];
    }
    pauseButton=[UIButton buttonWithType:UIButtonTypeSystem]; [pauseButton setTitle:@"暂停" forState:UIControlStateNormal];
    [pauseButton addTarget:self action:@selector(togglePause) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:pauseButton];
    qualityButton=[UIButton buttonWithType:UIButtonTypeSystem];
    qualityButton.titleLabel.font=[UIFont systemFontOfSize:12];
    [qualityButton setTitle:@"-- fps" forState:UIControlStateNormal];
    qualityButton.userInteractionEnabled=NO;
    qualityButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentRight;
    qualityButton.accessibilityLabel=@"画面帧数";
    [self.view addSubview:qualityButton];
    screenSwapButton=[UIButton buttonWithType:UIButtonTypeCustom];
    screenSwapButton.backgroundColor=UIColor.clearColor;
    screenSwapButton.layer.cornerRadius=10;
    screenSwapButton.layer.borderWidth=1;
    screenSwapButton.layer.borderColor=UIColor.darkGrayColor.CGColor;
    screenSwapButton.accessibilityLabel=@"放大副屏，与主屏交换";
    [screenSwapButton addTarget:self action:@selector(swapScreens) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:screenSwapButton];
    controlStyleButton=[[ControlStyleButton alloc] initWithFrame:CGRectZero];
    [controlStyleButton setTitleColor:UIColor.systemBlueColor forState:UIControlStateNormal];
    controlStyleButton.backgroundColor=[UIColor colorWithWhite:0.16 alpha:1];
    controlStyleButton.layer.cornerRadius=10;
    controlStyleButton.layer.borderWidth=1;
    controlStyleButton.layer.borderColor=UIColor.darkGrayColor.CGColor;
    controlStyleButton.titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [controlStyleButton addTarget:self action:@selector(toggleControlStyle) forControlEvents:UIControlEventTouchUpInside];
    [self updateControlStyleTitle];
    [self.view addSubview:controlStyleButton];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(background) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(foreground) name:UIApplicationDidBecomeActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllersChanged:) name:GCControllerDidConnectNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(controllersChanged:) name:GCControllerDidDisconnectNotification object:nil];
    [self controllersChanged:nil];
    NSBundle *files=NSBundle.mainBundle;
    for(NSString *relative in @[@"Game/Program.cia",@"Frameworks/Guest.framework/Guest",@"Fonts/NotoSansJP.ttf"]) {
        if(![[NSFileManager defaultManager] fileExistsAtPath:[files.bundlePath stringByAppendingPathComponent:relative]]) {
            [self stop:@"这是不含游戏资源的空壳。\n\n请在电脑上使用本项目的本机打包工具，加入你自己的受支持游戏文件、重编译游戏框架和开放字体，再签名安装完整 IPA。\n\n仅安装空壳不能启动游戏。"];
            return;
        }
    }
    sound=[Sound new];
    dispatch_async(worker,^{ @autoreleasepool {
        NSBundle *bundle=NSBundle.mainBundle;
        NSString *rom=[bundle.bundlePath stringByAppendingPathComponent:@"Game/Program.cia"];
        NSString *guest=[bundle.bundlePath stringByAppendingPathComponent:@"Frameworks/Guest.framework/Guest"];
        NSString *data=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        NSString *font=[bundle.bundlePath stringByAppendingPathComponent:@"Fonts/NotoSansJP.ttf"];
        char error[2048]={0};
        self->machine=rh_create(rom.UTF8String,guest.UTF8String,data.UTF8String,font.UTF8String,error,sizeof(error));
        NSString *message=[NSString stringWithUTF8String:error]?:@"启动失败";
        if(self->machine) {
            self->nextEmulationTime=CACurrentMediaTime();
            dispatch_async(self->worker,^{[self emulateOneFrame];});
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if (!self->machine) { [self stop:message]; return; }
            self->status.hidden=YES; self->lastFrameTime=CACurrentMediaTime();
            self->fpsWindowStart=self->lastFrameTime;
            self->display=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
            self->display.preferredFramesPerSecond=60;
            [self->display addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        });
    }});
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect safe=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);
    CGFloat w=safe.size.width,h=safe.size.height;
    BOOL landscape=w>h;
    BOOL controllerConnected=activeController!=nil;
    for(NSUInteger i=0;i<8;i++) buttons[i].hidden=controllerConnected;
    controlStyleButton.hidden=controllerConnected;
    pauseButton.hidden=landscape;
    qualityButton.hidden=landscape;
    buttons[10].hidden=YES;buttons[11].hidden=YES;
    screenSwapButton.hidden=!landscape;
    bottom.userInteractionEnabled=!landscape||screensSwapped;
    if(landscape) {
        CGFloat side=MIN(190,MAX(160,w*0.20)),gap=8;
        CGFloat availableW=w-2*side-16,availableH=h-46;
        CGFloat aspect=screensSwapped?320.0/240.0:400.0/240.0;
        CGFloat mainW=MIN(availableW,availableH*aspect),mainH=mainW/aspect;
        CGRect large=CGRectMake(CGRectGetMidX(safe)-mainW/2,safe.origin.y+(availableH-mainH)/2,mainW,mainH);
        CGFloat miniW=side-8,miniAspect=screensSwapped?400.0/240.0:320.0/240.0;
        CGRect mini=CGRectMake(safe.origin.x+4,safe.origin.y+4,miniW,miniW/miniAspect);
        top.frame=screensSwapped?mini:large;bottom.frame=screensSwapped?large:mini;
        screenSwapButton.frame=mini;
        screenSwapButton.accessibilityLabel=screensSwapped?@"放大主屏，与副屏交换":@"放大副屏，与主屏交换";
        CGFloat cross=MIN(side-8,MAX(148,h*0.43)),cell=(cross-2*gap)/3;
        CGFloat padX=safe.origin.x+(side-cross)/2,padY=CGRectGetMaxY(safe)-cross-8,step=cell+gap;
        buttons[0].frame=CGRectMake(padX+step,padY,cell,cell);
        buttons[1].frame=CGRectMake(padX,padY+step,cell,cell);
        buttons[2].frame=CGRectMake(padX+step,padY+2*step,cell,cell);
        buttons[3].frame=CGRectMake(padX+2*step,padY+step,cell,cell);
        CGFloat actionW=side-12,actionX=CGRectGetMaxX(safe)-side+4;
        CGFloat aH=MIN(166,h*0.39),aY=CGRectGetMaxY(safe)-aH-8;
        CGFloat smallH=MIN(58,MAX(44,h*0.13)),keyW=(actionW-gap)/2;
        if(dualAB) {
            buttons[4].frame=CGRectMake(actionX+keyW+gap,aY,keyW,aH);
            buttons[5].frame=CGRectMake(actionX,aY,keyW,aH);
            buttons[6].frame=CGRectMake(actionX,aY-smallH-gap,keyW,smallH);
            buttons[7].frame=CGRectMake(actionX+keyW+gap,aY-smallH-gap,keyW,smallH);
        } else {
            CGFloat secondary=(actionW-2*gap)/3;
            buttons[4].frame=CGRectMake(actionX,aY,actionW,aH);
            for(NSUInteger i=5;i<8;i++) buttons[i].frame=CGRectMake(actionX+(i-5)*(secondary+gap),aY-smallH-gap,secondary,smallH);
        }
        buttons[8].frame=CGRectMake(CGRectGetMidX(safe)-66,CGRectGetMaxY(safe)-38,62,32);
        buttons[9].frame=CGRectMake(CGRectGetMidX(safe)+4,CGRectGetMaxY(safe)-38,62,32);
        controlStyleButton.frame=CGRectMake(CGRectGetMaxX(safe)-82,safe.origin.y+6,76,32);
        controlStyleButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        buttons[4].titleLabel.font=[UIFont boldSystemFontOfSize:48];
        for(NSUInteger i=0;i<4;i++) buttons[i].titleLabel.font=[UIFont boldSystemFontOfSize:32];
        for(NSUInteger i=5;i<8;i++) buttons[i].titleLabel.font=[UIFont boldSystemFontOfSize:26];
        buttons[5].titleLabel.font=[UIFont boldSystemFontOfSize:dualAB?40:26];
        status.frame=CGRectInset(safe,20,20);
        return;
    }
    CGFloat controls=landscape?156:MIN(320,MAX(270,h*0.36));
    CGFloat scale=landscape?MIN((w-12)/720,(h-controls)/240):MIN(w/400,(h-controls-12)/480);
    CGFloat y=safe.origin.y;
    if (landscape) {
        CGFloat left=safe.origin.x+(w-720*scale-12)/2;
        top.frame=CGRectMake(left,y,400*scale,240*scale);
        bottom.frame=CGRectMake(CGRectGetMaxX(top.frame)+12,y,320*scale,240*scale);
    } else {
        top.frame=CGRectMake(CGRectGetMidX(safe)-200*scale,y,400*scale,240*scale);
        bottom.frame=CGRectMake(CGRectGetMidX(safe)-160*scale,CGRectGetMaxY(top.frame)+8,320*scale,240*scale);
    }
    CGFloat base=CGRectGetMaxY(safe)-controls+10,left=safe.origin.x+4,right=CGRectGetMaxX(safe)-4;
    // Four separate hit targets around an empty center: a true four-way
    // cross, with room to hold a direction and A at the same time.
    CGFloat unit=MIN(44,(w-24)/8.0),gap=4,step=unit+gap;
    buttons[0].frame=CGRectMake(left+step,base,unit,unit);
    buttons[1].frame=CGRectMake(left,base+step,unit,unit);
    buttons[2].frame=CGRectMake(left+step,base+2*step,unit,unit);
    buttons[3].frame=CGRectMake(left+2*step,base+step,unit,unit);
    // The larger primary target stays below the secondary row and clear
    // of both game screens, including the touch-sensitive lower screen.
    CGFloat aWidth=MIN(156,w*0.42),aHeight=88,secondary=(aWidth-2*gap)/3;
    buttons[4].frame=CGRectMake(right-aWidth,base+52,aWidth,aHeight);
    buttons[5].frame=CGRectMake(right-aWidth,base,secondary,44);
    buttons[6].frame=CGRectMake(right-aWidth+secondary+gap,base,secondary,44);
    buttons[7].frame=CGRectMake(right-secondary,base,secondary,44);
    CGFloat center=CGRectGetMidX(safe);
    status.frame=CGRectInset(safe,20,20);
    buttons[4].titleLabel.font=[UIFont boldSystemFontOfSize:landscape?36:48];
    for (NSUInteger i=0;i<4;i++) buttons[i].titleLabel.font=[UIFont boldSystemFontOfSize:28];
    for (NSUInteger i=5;i<8;i++) buttons[i].titleLabel.font=[UIFont boldSystemFontOfSize:23];
    if (landscape) {
        buttons[8].frame=CGRectMake(center-58,base+66,54,36);
        buttons[9].frame=CGRectMake(center+4,base+66,54,36);
        buttons[10].frame=CGRectMake(center-56,base+112,48,32);
        buttons[11].frame=CGRectMake(center+8,base+112,48,32);
        pauseButton.frame=CGRectMake(center-77,base+10,64,38);
        qualityButton.frame=CGRectMake(center+1,base+16,84,27);
    } else {
        // Reserve each half of the portrait control area for one thumb.
        // Leave a center gap and keep the lower touchscreen unobstructed.
        CGFloat halfWidth=(w-24)/2,mainHeight=controls-100;
        CGFloat cell=(MIN(halfWidth,mainHeight)-2*gap)/3;
        CGFloat cross=3*cell+2*gap,padLeft=safe.origin.x+8+(halfWidth-cross)/2;
        CGFloat padTop=base+(mainHeight-cross)/2,padStep=cell+gap;
        buttons[0].frame=CGRectMake(padLeft+padStep,padTop,cell,cell);
        buttons[1].frame=CGRectMake(padLeft,padTop+padStep,cell,cell);
        buttons[2].frame=CGRectMake(padLeft+padStep,padTop+2*padStep,cell,cell);
        buttons[3].frame=CGRectMake(padLeft+2*padStep,padTop+padStep,cell,cell);
        CGFloat actionLeft=center+4,smallHeight=MIN(64,MAX(52,mainHeight*0.28));
        CGFloat smallWidth=(halfWidth-2*gap)/3;
        if(dualAB) {
            CGFloat keyWidth=(halfWidth-gap)/2,actionY=base+smallHeight+8,actionHeight=mainHeight-smallHeight-8;
            buttons[4].frame=CGRectMake(actionLeft+keyWidth+gap,actionY,keyWidth,actionHeight);
            buttons[5].frame=CGRectMake(actionLeft,actionY,keyWidth,actionHeight);
            buttons[6].frame=CGRectMake(actionLeft,base,keyWidth,smallHeight);
            buttons[7].frame=CGRectMake(actionLeft+keyWidth+gap,base,keyWidth,smallHeight);
        } else {
            buttons[4].frame=CGRectMake(actionLeft,base+smallHeight+8,halfWidth,mainHeight-smallHeight-8);
            buttons[5].frame=CGRectMake(actionLeft,base,smallWidth,smallHeight);
            buttons[6].frame=CGRectMake(actionLeft+smallWidth+gap,base,smallWidth,smallHeight);
            buttons[7].frame=CGRectMake(actionLeft+2*(smallWidth+gap),base,smallWidth,smallHeight);
        }
        for (NSUInteger i=0;i<4;i++) buttons[i].titleLabel.font=[UIFont boldSystemFontOfSize:MIN(36,MAX(28,cell*0.52))];
        for (NSUInteger i=5;i<8;i++) buttons[i].titleLabel.font=[UIFont boldSystemFontOfSize:26];
        buttons[5].titleLabel.font=[UIFont boldSystemFontOfSize:dualAB?40:26];
        CGFloat utility=base+controls-96;
        buttons[8].frame=CGRectMake(center-92,utility,54,38);
        buttons[9].frame=CGRectMake(center+38,utility,54,38);
        buttons[10].frame=CGRectMake(safe.origin.x+8,utility,44,38);
        buttons[11].frame=CGRectMake(CGRectGetMaxX(safe)-52,utility,44,38);
        pauseButton.frame=CGRectMake(center-32,utility,64,38);
        qualityButton.frame=CGRectMake(CGRectGetMaxX(safe)-64,utility,56,38);
        controlStyleButton.frame=CGRectMake(safe.origin.x+8,utility,MIN(76,w/2-108),38);
        controlStyleButton.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    }
}
- (void)clearInputs {
    [inputLock lock];held=latched=0;touchDown=touchLatched=NO;rh_controller_clear(&controllerInput);[inputLock unlock];
    for(UIButton *button in buttons) button.alpha=1;
}
- (void)readController:(GCExtendedGamepad *)pad {
    if(!pad||activeController.extendedGamepad!=pad)return;
    RHControllerButtons b={
        .bottom=pad.buttonA.isPressed,.right=pad.buttonB.isPressed,
        .left=pad.buttonX.isPressed,.top=pad.buttonY.isPressed,
        .dpadUp=pad.dpad.up.isPressed,.dpadDown=pad.dpad.down.isPressed,
        .dpadLeft=pad.dpad.left.isPressed,.dpadRight=pad.dpad.right.isPressed,
        .stickUp=pad.leftThumbstick.up.isPressed,.stickDown=pad.leftThumbstick.down.isPressed,
        .stickLeft=pad.leftThumbstick.left.isPressed,.stickRight=pad.leftThumbstick.right.isPressed,
        .shoulderLeft=pad.leftShoulder.isPressed,.shoulderRight=pad.rightShoulder.isPressed,
        .menu=pad.buttonMenu.isPressed,.options=pad.buttonOptions.isPressed
    };
    BOOL enabled=!paused&&!keyboardActive&&!failed&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive;
    [inputLock lock];rh_controller_update(&controllerInput,rh_controller_mask(b),enabled);[inputLock unlock];
}
- (void)controllersChanged:(NSNotification *)notification {
    if(!NSThread.isMainThread) {
        __weak Game *weakSelf=self;
        dispatch_async(dispatch_get_main_queue(),^{[weakSelf controllersChanged:notification];});return;
    }
    GCController *removed=[notification.name isEqualToString:GCControllerDidDisconnectNotification]?notification.object:nil;
    NSArray<GCController *> *controllers=GCController.controllers;
    GCController *selected=nil;
    // Keep the current player when a second controller connects.
    if(activeController&&activeController!=removed&&[controllers containsObject:activeController]&&activeController.extendedGamepad) selected=activeController;
    if(!selected)for(GCController *candidate in controllers) {
        if(candidate!=removed&&candidate.extendedGamepad) {selected=candidate;break;}
    }
    if(selected==activeController) { [self readController:selected.extendedGamepad];return; }
    activeController.extendedGamepad.valueChangedHandler=nil;
    [inputLock lock];
    controllerInput=(RHControllerState){0};
    // Connecting hides the face/direction buttons. Release their touch
    // source, while keeping the independent lower-screen touch intact.
    if(selected)held=latched=0;
    [inputLock unlock];
    for(UIButton *button in buttons)button.alpha=1;
    activeController=selected;
    if(selected) {
        selected.handlerQueue=dispatch_get_main_queue();
        __weak Game *weakSelf=self;
        selected.extendedGamepad.valueChangedHandler=^(GCExtendedGamepad *pad,GCControllerElement *element) {
            (void)element;[weakSelf readController:pad];
        };
        [self readController:selected.extendedGamepad];
        [inputLock lock];rh_controller_clear(&controllerInput);[inputLock unlock];
    }
    [self.view setNeedsLayout];
    // Do not log controller identifiers or every button press.
    rh_note(selected?"controller: connected; Nintendo positions; touch action keys hidden":"controller: disconnected; touch controls restored");
}
- (void)dealloc {
    activeController.extendedGamepad.valueChangedHandler=nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)updateControlStyleTitle {
    [controlStyleButton setTitle:dualAB?@"按键: A/B":@"按键: 大A" forState:UIControlStateNormal];
    controlStyleButton.accessibilityLabel=dualAB?@"当前为并排大 A/B 按键":@"当前为大 A 按键";
    controlStyleButton.accessibilityHint=@"点按切换按键样式，选择会自动保存";
}
- (void)toggleControlStyle {
    [self clearInputs];dualAB=!dualAB;
    [[NSUserDefaults standardUserDefaults] setBool:dualAB forKey:@"rh3ds.dualABControls"];
    [self updateControlStyleTitle];
    [self.view setNeedsLayout];[self.view layoutIfNeeded];
    rh_note(dualAB?"controls: large A/B layout":"controls: large A layout");
}
- (void)swapScreens {
    [self clearInputs];screensSwapped=!screensSwapped;
    [self.view setNeedsLayout];[self.view layoutIfNeeded];
    rh_note(screensSwapped?"layout: lower screen enlarged":"layout: upper screen enlarged");
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self clearInputs];
    if(size.width>size.height&&paused&&!keyboardActive&&!failed&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive) {
        paused=NO;[sound pause:NO];[pauseButton setTitle:@"暂停" forState:UIControlStateNormal];
    }
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}
- (void)resetFPS {
    fpsWindowStart=CACurrentMediaTime();logicFrames=visualFrames=0;
    [videoLock lock];seenLogicFrames=totalLogicFrames;[videoLock unlock];
}
- (void)down:(UIButton *)button {
    [inputLock lock];held|=(uint32_t)button.tag;latched|=(uint32_t)button.tag;[inputLock unlock];button.alpha=0.5;
}
- (void)up:(UIButton *)button {
    [inputLock lock];held&=~(uint32_t)button.tag;[inputLock unlock];button.alpha=1;
}
- (void)touch:(BOOL)down point:(CGPoint)point {
    CGPoint mapped=CGPointMake(MAX(0,MIN(319,point.x/bottom.bounds.size.width*320)),MAX(0,MIN(239,point.y/bottom.bounds.size.height*240)));
    [inputLock lock];touchDown=down;if(down)touchLatched=YES;touchPoint=mapped;[inputLock unlock];
}
// Exactly one emulated frame per worker job. The display refresh never
// batches game frames or holds the producer while waiting on the main queue.
- (void)emulateOneFrame {
    @autoreleasepool {
        if(failed||!machine)return;
        if(paused||keyboardActive) {
            nextEmulationTime=CACurrentMediaTime();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(FramePeriod*NSEC_PER_SEC)),worker,^{[self emulateOneFrame];});
            return;
        }
        [inputLock lock];
        uint32_t keys=held|latched|rh_controller_take(&controllerInput);latched=0;
        BOOL touched=touchDown||touchLatched;touchLatched=NO;
        uint16_t x=(uint16_t)touchPoint.x,y=(uint16_t)touchPoint.y;
        [inputLock unlock];
        int result=rh_step(machine,keys,touched,x,y);
        int16_t samples[8192];size_t count=rh_audio(machine,samples,4096);
        [sound push:samples frames:count];
        if(result) {
            failed=YES;NSString *message=[NSString stringWithUTF8String:rh_error(machine)]?:@"运行停止";
            dispatch_async(dispatch_get_main_queue(),^{[self stop:message];});return;
        }
        uint64_t generation=rh_video_generation(machine);
        UIImage *upper=nil,*lower=nil;
        if(generation!=copiedGeneration) {
            const uint8_t *pixels=rh_screen(machine,0,&count);upper=Image(pixels,count,400);
            pixels=rh_screen(machine,1,&count);lower=Image(pixels,count,320);
            copiedGeneration=generation;
        }
        [videoLock lock];
        totalLogicFrames++;
        if(upper&&lower) {pendingUpper=upper;pendingLower=lower;pendingGeneration=generation;}
        [videoLock unlock];
        if(++metricFrames>=120) {metricFrames=0;rh_note([sound diagnostics].UTF8String);}
        const char *request=rh_keyboard(machine);
        if(request&&!keyboardActive) {
            keyboardActive=YES;NSData *data=[NSData dataWithBytes:request length:strlen(request)];
            dispatch_async(dispatch_get_main_queue(),^{[self showKeyboard:data];});
        }
        double now=CACurrentMediaTime();
        nextEmulationTime=rh_next_frame_deadline(nextEmulationTime,now,FramePeriod);
        double wait=MAX(0.0,nextEmulationTime-now);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(wait*NSEC_PER_SEC)),worker,^{[self emulateOneFrame];});
    }
}
// UIKit presents the latest completed pair at the phone's display cadence.
// Repeated cached images are excluded from the visible FPS counter.
- (void)tick:(CADisplayLink *)link {
    if(paused||keyboardActive||failed||!machine)return;
    [videoLock lock];
    UIImage *upper=pendingUpper,*lower=pendingLower;
    uint64_t generation=pendingGeneration,logic=totalLogicFrames;
    [videoLock unlock];
    logicFrames+=(unsigned)(logic-seenLogicFrames);seenLogicFrames=logic;
    if(generation!=shownVideoGeneration&&upper&&lower) {
        shownVideoGeneration=generation;visualFrames++;top.image=upper;bottom.image=lower;
    }
    double now=CACurrentMediaTime(),elapsed=now-fpsWindowStart;
    if(elapsed>=1.0) {
        double shown=visualFrames/elapsed,running=logicFrames/elapsed;
        [qualityButton setTitle:[NSString stringWithFormat:@"%.0f fps",shown] forState:UIControlStateNormal];
        NSString *metrics=[NSString stringWithFormat:@"actual pacing: visual %.2f fps, emulation %.2f fps, window %.3fs; independent producer",shown,running,elapsed];
        dispatch_async(worker,^{rh_note(metrics.UTF8String);});
        fpsWindowStart=now;logicFrames=visualFrames=0;
    }
}
- (void)showKeyboard:(NSData *)data {
    NSDictionary *request=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!request) {keyboardActive=NO;return;}
    keyboardActive=YES;[self clearInputs];[sound pause:YES];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:request[@"hint"] message:@"请输入存档名称" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=request[@"text"];field.autocorrectionType=UITextAutocorrectionTypeNo;}];
    NSArray *labels=request[@"buttons"];
    for(NSUInteger i=0;i<labels.count;i++) {
        NSString *title=[labels[i] length]?labels[i]:(i+1==labels.count?@"确定":@"取消");
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            NSString *value=alert.textFields.firstObject.text?:@"";
            dispatch_async(self->worker,^{rh_answer(self->machine,value.UTF8String,(uint32_t)i);
                dispatch_async(dispatch_get_main_queue(),^{self->keyboardActive=NO;[self->sound pause:self->paused];[self resetFPS];});});
        }]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)togglePause {
    paused=!paused;[sound pause:paused];[self clearInputs];[self resetFPS];
    [pauseButton setTitle:paused?@"继续":@"暂停" forState:UIControlStateNormal];
}
- (void)toggleQuality {
    fullDrawing=!fullDrawing;
    [qualityButton setTitle:fullDrawing?@"画面:逐帧":@"画面:自动" forState:UIControlStateNormal];
    BOOL full=fullDrawing;
    dispatch_async(worker,^{if(self->machine)rh_full_drawing(self->machine,full);});
}
- (void)background { wasRunningBeforeBackground=!paused;paused=YES;[sound pause:YES];[self clearInputs];[pauseButton setTitle:@"继续" forState:UIControlStateNormal]; }
- (void)foreground {
    if(wasRunningBeforeBackground&&!failed) {paused=NO;[sound pause:keyboardActive];[pauseButton setTitle:@"暂停" forState:UIControlStateNormal];}
    [self resetFPS];
    [self controllersChanged:nil];
}
- (void)stop:(NSString *)message {
    failed=YES;[sound pause:YES];[display invalidate];
    status.hidden=NO;status.text=[NSString stringWithFormat:@"%@\n\n诊断日志保存在“文件”中的本应用目录 / log.txt",message];
}
@end

@interface App : UIResponder <UIApplicationDelegate>
@property(strong,nonatomic) UIWindow *window;
@end
@implementation App
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    app.idleTimerDisabled=YES;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[Game new];[self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(App.class)); } }
