//! Serialized C interface for the experimental iOS frontend. CPU AOT has
//! interpreter fallback; GPU shader JIT is disabled in the pinned runtime.
use std::{ffi::{c_char, CStr, CString}, path::PathBuf, sync::Mutex, io::Write};
use zakuro_common::Screen;
use zakuro_core::{Config, System, FrameOutcome, services::hid::{InputState, PadState}};

struct FileLogger(Mutex<std::fs::File>);
impl log::Log for FileLogger {
    fn enabled(&self, _: &log::Metadata) -> bool { true }
    fn log(&self, record: &log::Record) {
        if let Ok(mut file) = self.0.lock() { let _ = writeln!(file,"{} {} {}",record.level(),record.target(),record.args()); }
    }
    fn flush(&self) { if let Ok(mut file)=self.0.lock() { let _=file.flush(); } }
}

pub struct Mobile {
    system: System,
    screens: [Vec<u8>;2],
    audio: Vec<[i16;2]>,
    error: CString,
    keyboard: CString,
    measured_frames: u32,
    step_time: std::time::Duration,
    worst_step: std::time::Duration,
    render_interval: u32,
    render_elapsed: f64,
    skip_elapsed: f64,
    full_drawing: bool,
    fixed_interval: Option<u32>,
    drawn_frames: u32,
    skipped_frames: u32,
    video_generation: u64,
    hardware: bool,
    gpu_start_marker: Option<PathBuf>,
}

/// Local diagnostic snapshot, without saves, personal text or memory contents.
pub unsafe fn diagnostic(m: *mut Mobile) -> serde_json::Value {
    let m=&mut *m;
    let mut values=std::collections::BTreeMap::new();
    let mut stacks=std::collections::BTreeMap::new();
    for t in &m.system.kernel.threads {
        let mut bytes=vec![0u8;512];m.system.memory.read_bytes(t.context.regs[13],&mut bytes);
        stacks.insert(t.id,bytes.chunks_exact(4).map(|v|format!("{:08X}",u32::from_le_bytes(v.try_into().unwrap()))).collect::<Vec<_>>());
        if let Some(address)=t.wait_address {
            let mut bytes=[0u8;4];m.system.memory.read_bytes(address,&mut bytes);
            values.insert(format!("{address:08X}"),u32::from_le_bytes(bytes));
        }
    }
    let mut gsp=vec![0u8;0x1000];m.system.memory.read_bytes(m.system.services.gsp.shared_memory_address,&mut gsp);
    serde_json::json!({"frame":m.system.frames,"cpu_pc":m.system.cpu.regs[15],"stacks":stacks,
        "gsp":m.system.services.gsp,"gsp_shared":gsp,
        "current_thread":m.system.kernel.current_thread,"all_blocked":m.system.kernel.all_blocked,
        "visual_interval":m.render_interval,"suppressed_draws":m.system.gpu.suppressed_draws,
        "hid_index":m.system.services.hid.pad_index,"hid_previous":m.system.services.hid.previous.bits(),
        "keyboard":m.system.keyboard_request().is_some(),"wait_values":values,
        "threads":m.system.kernel.threads.iter().map(|t|serde_json::json!({"id":t.id,"name":t.name,
            "pc":t.context.regs[15],"status":format!("{:?}",t.status),"objects":t.wait_objects,
            "address":t.wait_address,"wakeup":t.wakeup_at,"registers":t.context.regs,
            "waiting_objects":t.wait_objects.iter().map(|id|format!("{:?}",m.system.kernel.objects.get(*id))).collect::<Vec<_>>()
            })).collect::<Vec<_>>(),
        "recent":m.system.recent_instructions()})
}
fn clean(text: impl AsRef<str>) -> CString { CString::new(text.as_ref().replace('\0'," ")).unwrap() }
unsafe fn text<'a>(p: *const c_char) -> &'a str { if p.is_null() { "" } else { CStr::from_ptr(p).to_str().unwrap_or("") } }
unsafe fn write_error(out: *mut c_char, capacity: usize, msg: &str) {
    if out.is_null() || capacity == 0 { return; }
    let msg=clean(msg); let count=msg.as_bytes().len().min(capacity-1);
    std::ptr::copy_nonoverlapping(msg.as_ptr(),out,count); *out.add(count)=0;
}

/// Every call touching one handle must run serially. All paths are local.
#[no_mangle]
pub unsafe extern "C" fn rh_create(rom: *const c_char, guest: *const c_char, data: *const c_char,
    font: *const c_char, error: *mut c_char, capacity: usize) -> *mut Mobile {
    let result=std::panic::catch_unwind(|| -> Result<Mobile,String> {
        let data=PathBuf::from(text(data));
        std::fs::create_dir_all(&data).map_err(|e|e.to_string())?;
        if let Ok(file)=std::fs::OpenOptions::new().create(true).truncate(true).write(true).open(data.join("log.txt")) {
            let logger=Box::leak(Box::new(FileLogger(Mutex::new(file))));
            if log::set_logger(logger).is_ok() { log::set_max_level(log::LevelFilter::Info); }
        }
        std::env::set_var("RH3DS_FONT_PATH",text(font));
        std::env::set_var("RH3DS_CACHE_DIRECTORY",data.join("cache"));
        let marker=data.join("gpu-starting.txt");
        let forced_software=data.join("software-renderer.txt").exists();
        let interrupted=marker.exists();
        let request_gpu=(cfg!(target_os="ios") || std::env::var_os("RH3DS_GPU").is_some()) && !forced_software && !interrupted;
        if cfg!(target_os="ios") {
            std::env::set_var("MVK_CONFIG_API_VERSION_TO_ADVERTISE","4206592"); // Vulkan 1.3.0, supported by pinned MoltenVK 1.4.2.
            std::env::set_var("MVK_CONFIG_USE_METAL_PRIVATE_API","0");
            // The generic GPU combiner preserves this title's multi-stage
            // effects; the asynchronous specialized path lost draws in
            // sustained desktop checks. This remains GPU fragment work.
            std::env::set_var("ZAKURO_GENERIC_SHADERS","1");
            if let Some(frameworks)=PathBuf::from(text(guest)).parent().and_then(|p|p.parent()) {
                std::env::set_var("RH3DS_VULKAN_LIBRARY",frameworks.join("MoltenVK.framework/MoltenVK"));
            }
        }
        if request_gpu {std::fs::write(&marker,b"Hardware renderer initialization and first 120 frames\n").map_err(|e|e.to_string())?;}
        log::info!("Experimental iOS performance3: negotiated Vulkan instance extensions; independent frame producer; Metal via MoltenVK requested={request_gpu}; previous GPU startup interrupted={interrupted}; forced software={forced_software}; shader CPU JIT disabled");
        let config=Config { recompiled: Some(PathBuf::from(text(guest))), data_dir: Some(data),
            language: 0, hardware_renderer: request_gpu, texture_packs: false, ..Config::default() };
        let mut system=zakuro_core::loader::load(text(rom),config).map_err(|e|e.to_string())?;
        let hardware=system.gpu.has_hardware_renderer();
        log::info!("Selected renderer: {}",if hardware {"hardware Vulkan/Metal, full visual frame cadence"} else {"software fallback, adaptive visual cadence"});
        if request_gpu&&!hardware {let _=std::fs::remove_file(&marker);}
        if system.recompiled.is_none() { return Err("Could not load the signed ARM64 game framework; see log.txt".into()); }
        // The app bundle is read-only; do not write hints next to its framework.
        system.hints=None;
        Ok(Mobile { system, screens:[Vec::new(),Vec::new()],audio:Vec::new(),error:clean(""),keyboard:clean(""),
            measured_frames:0,step_time:std::time::Duration::ZERO,worst_step:std::time::Duration::ZERO,
            render_interval:1,render_elapsed:0.0,skip_elapsed:0.002,full_drawing:false,
            fixed_interval:std::env::var("RH3DS_RENDER_INTERVAL").ok().and_then(|v|v.parse::<u32>().ok()).map(|v|v.clamp(1,3)),
            drawn_frames:0,skipped_frames:0,video_generation:0,hardware,
            gpu_start_marker:hardware.then_some(marker) })
    });
    match result {
        Ok(Ok(mobile)) => Box::into_raw(Box::new(mobile)),
        Ok(Err(msg)) => { write_error(error,capacity,&msg); std::ptr::null_mut() },
        Err(_) => { write_error(error,capacity,"Runtime initialization panicked; see log.txt"); std::ptr::null_mut() }
    }
}

#[no_mangle]
pub unsafe extern "C" fn rh_step(m: *mut Mobile, buttons:u32, touch:i32, x:u16, y:u16) -> i32 {
    let Some(m)=m.as_mut() else { return -1; };
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let started=std::time::Instant::now();
        let interval=if m.hardware||m.full_drawing {1} else {m.fixed_interval.unwrap_or(m.render_interval)};
        let draw=m.screens[0].is_empty() || (m.system.frames+1)%interval as u64==0;
        m.system.gpu.suppress_visual_draws(!draw);
        m.system.set_input(InputState { buttons:PadState::from_bits_retain(buttons),
            touch:(touch!=0).then_some((x.min(319),y.min(239))), ..InputState::default() });
        let outcome=m.system.run_frame();
        if m.system.frames>=120 {
            if let Some(marker)=m.gpu_start_marker.take() {let _=std::fs::remove_file(marker);}
        }
        m.audio=m.system.take_audio();
        // Never present a skipped target: fills/transfers may have cleared
        // it. Keep the last complete pair of screens until the next draw.
        if draw {
            // Keep CPU readback coherent until the asynchronous presenter
            // path has been validated on iOS. GPU drawing still avoids
            // the software pixel combiner's dominant cost.
            m.screens[0]=m.system.read_screen(Screen::Top);
            m.screens[1]=m.system.read_screen(Screen::Bottom);
            m.drawn_frames+=1;
            m.video_generation+=1;
        } else { m.skipped_frames+=1; }
        let elapsed=started.elapsed();
        let smooth=|old:f64,new:f64| if old==0.0 {new} else {old*0.8+new*0.2};
        if draw { m.render_elapsed=smooth(m.render_elapsed,elapsed.as_secs_f64()); }
        else { m.skip_elapsed=smooth(m.skip_elapsed,elapsed.as_secs_f64()); }
        m.render_interval=visual_interval(m.render_elapsed,m.skip_elapsed);
        m.step_time+=elapsed;m.worst_step=m.worst_step.max(elapsed);m.measured_frames+=1;
        if m.system.frames%120==0 {
            log::info!("{} | step avg {:.2}ms max {:.2}ms | visual interval {} drawn {} skipped {}",m.system.status_line(),
                m.step_time.as_secs_f64()*1000.0/m.measured_frames as f64,m.worst_step.as_secs_f64()*1000.0,
                interval,m.drawn_frames,m.skipped_frames);
            m.step_time=std::time::Duration::ZERO;m.worst_step=std::time::Duration::ZERO;m.measured_frames=0;
            m.drawn_frames=0;m.skipped_frames=0;
            log::logger().flush();
        }
        if !m.system.fatal_errors.is_empty() { return Err(m.system.fatal_errors.join("; ")); }
        if outcome!=FrameOutcome::Completed { return Err(format!("Stopped: {outcome:?}")); }
        Ok(())
    })) {
        Ok(Ok(())) => 0,
        Ok(Err(msg)) => { log::error!("{msg}");m.error=clean(msg);log::logger().flush();-1 },
        Err(_) => { m.error=clean("Runtime panicked; see log.txt");log::error!("Runtime panic");log::logger().flush();-1 }
    }
}

#[no_mangle]
pub unsafe extern "C" fn rh_screen(m:*const Mobile, screen:u32, length:*mut usize)->*const u8 {
    let Some(m)=m.as_ref() else { return std::ptr::null(); };
    let bytes=&m.screens[(screen!=0) as usize];
    if !length.is_null() { *length=bytes.len(); }
    bytes.as_ptr()
}
#[no_mangle]
pub unsafe extern "C" fn rh_audio(m:*mut Mobile,out:*mut i16,capacity:usize)->usize {
    let Some(m)=m.as_mut() else { return 0; };
    if out.is_null() { return 0; }
    let frames=capacity.min(m.audio.len());
    std::ptr::copy_nonoverlapping(m.audio.as_ptr() as *const i16,out,frames*2);
    m.audio.drain(..frames);frames
}
#[no_mangle]
pub unsafe extern "C" fn rh_error(m:*const Mobile)->*const c_char {
    m.as_ref().map_or(std::ptr::null(),|m|m.error.as_ptr())
}
#[no_mangle]
pub unsafe extern "C" fn rh_keyboard(m:*mut Mobile)->*const c_char {
    let Some(m)=m.as_mut() else { return std::ptr::null(); };
    match m.system.keyboard_request() {
        None=>std::ptr::null(),
        Some(request)=>{m.keyboard=clean(serde_json::json!({"hint":request.hint,"text":request.text,
            "maximum":request.max_length,"buttons":request.buttons}).to_string());m.keyboard.as_ptr()}
    }
}
#[no_mangle]
pub unsafe extern "C" fn rh_answer(m:*mut Mobile,value:*const c_char,button:u32) {
    if let Some(m)=m.as_mut() { m.system.answer_keyboard(text(value),button as usize); }
}
#[no_mangle]
pub unsafe extern "C" fn rh_destroy(m:*mut Mobile) { if !m.is_null() { drop(Box::from_raw(m));log::logger().flush(); } }

#[no_mangle]
pub unsafe extern "C" fn rh_note(message:*const c_char) { log::info!("frontend {}",text(message)); }

fn visual_interval(draw_seconds:f64,skip_seconds:f64)->u32 {
    // Leave some headroom for UIKit/audio scheduling. Keep the full frame
    // rate for light scenes, at least 20 visual frames/s for heavy scenes.
    let budget=0.0145;
    if draw_seconds<=budget {return 1;}
    let available=(budget-skip_seconds).max(0.003);
    ((draw_seconds-skip_seconds)/available).ceil().clamp(1.0,3.0) as u32
}

#[no_mangle]
pub unsafe extern "C" fn rh_full_drawing(m:*mut Mobile,full:i32) {
    if let Some(m)=m.as_mut() { m.full_drawing=full!=0;log::info!("Drawing mode: {}",if m.full_drawing {"every frame"} else {"adaptive"}); }
}

#[no_mangle]
pub unsafe extern "C" fn rh_video_generation(m:*const Mobile)->u64 {
    m.as_ref().map_or(0,|m|m.video_generation)
}

#[cfg(test)]
mod mobile_tests {
    use super::*;
    #[test]
    fn pacing_restores_full_rate_for_light_scenes_and_bounds_heavy_scenes() {
        assert_eq!(visual_interval(0.009,0.002),1);
        assert_eq!(visual_interval(0.023,0.002),2);
        assert_eq!(visual_interval(0.038,0.002),3);
        assert_eq!(visual_interval(1.0,0.2),3);
        assert_eq!(visual_interval(0.009,0.002),1);
    }
}
