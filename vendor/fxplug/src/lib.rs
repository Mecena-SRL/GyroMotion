// SPDX-License-Identifier: GPL-3.0-or-later
//! Mecena Stabilize for Final Cut Pro. The FxPlug (Swift) cannot be an OpenFX host, so the plugin base of the Resolve
//! effect (vendor/common) runs here behind a small C interface (fcp/Sources/Core/MecenaCore.h): the same loading of the
//! clip's motion data, the same modes and the same Gyroflow rendering, with the panel's values handed over by the FxPlug.
use std::collections::HashMap;
use std::ffi::{ c_char, c_void, CStr };
use std::sync::{ Arc, LazyLock };

use gyroflow_plugin_base::*;
use gyroflow_plugin_base::parking_lot::Mutex;

#[derive(Clone, Debug)]
enum Value { F(f64), B(bool), I(i32), S(String) }

/// The parameters of the OpenFX panel, held in memory: the defaults of `get_param_definitions`, then what the FxPlug sets
struct MemParams { values: HashMap<Params, Value> }

impl MemParams {
    fn new() -> Self {
        fn walk(v: &mut HashMap<Params, Value>, defs: Vec<ParameterType>) {
            for d in defs {
                let (id, val) = match d {
                    ParameterType::Group { parameters, .. } => { walk(v, parameters); continue; }
                    ParameterType::HiddenString { id } => (id, Value::S(String::new())),
                    ParameterType::Text { id, .. } | ParameterType::TextBox { id, .. } | ParameterType::Button { id, .. } => (id, Value::S(String::new())),
                    ParameterType::Slider { id, default, .. } => (id, Value::F(default)),
                    ParameterType::Checkbox { id, default, .. } => (id, Value::B(default)),
                    ParameterType::Select { id, options, default, .. } => (id, Value::I(options.iter().position(|x| *x == default).unwrap_or(0) as i32)),
                };
                if let Ok(p) = id.parse::<Params>() { v.insert(p, val); }
            }
        }
        let mut values = HashMap::new();
        walk(&mut values, GyroflowPluginBase::get_param_definitions().into());
        Self { values }
    }
    fn get(&self, p: Params) -> PluginResult<&Value> { self.values.get(&p).ok_or_else(|| format!("{p:?} non definito").into()) }
}

impl GyroflowPluginParams for MemParams {
    fn set_enabled(&mut self, _: Params, _: bool) -> PluginResult<()> { Ok(()) }
    fn set_label(&mut self, _: Params, _: &str) -> PluginResult<()> { Ok(()) }
    fn set_hint(&mut self, _: Params, _: &str) -> PluginResult<()> { Ok(()) }
    fn set_f64(&mut self, p: Params, v: f64) -> PluginResult<()> { self.values.insert(p, Value::F(v)); Ok(()) }
    fn get_f64(&self, p: Params) -> PluginResult<f64> { match self.get(p)? { Value::F(v) => Ok(*v), Value::I(v) => Ok(*v as f64), x => Err(format!("{p:?}: {x:?}").into()) } }
    fn get_f64_at_time(&self, p: Params, _: TimeType) -> PluginResult<f64> { self.get_f64(p) }
    fn set_bool(&mut self, p: Params, v: bool) -> PluginResult<()> { self.values.insert(p, Value::B(v)); Ok(()) }
    fn get_bool(&self, p: Params) -> PluginResult<bool> { match self.get(p)? { Value::B(v) => Ok(*v), x => Err(format!("{p:?}: {x:?}").into()) } }
    fn get_bool_at_time(&self, p: Params, _: TimeType) -> PluginResult<bool> { self.get_bool(p) }
    fn set_string(&mut self, p: Params, v: &str) -> PluginResult<()> { self.values.insert(p, Value::S(v.to_owned())); Ok(()) }
    fn get_string(&self, p: Params) -> PluginResult<String> { match self.get(p)? { Value::S(v) => Ok(v.clone()), x => Err(format!("{p:?}: {x:?}").into()) } }
    fn set_i32(&mut self, p: Params, v: i32) -> PluginResult<()> { self.values.insert(p, Value::I(v)); Ok(()) }
    fn get_i32(&self, p: Params) -> PluginResult<i32> { match self.get(p)? { Value::I(v) => Ok(*v), Value::F(v) => Ok(*v as i32), x => Err(format!("{p:?}: {x:?}").into()) } }
    // Final Cut animates Intensità only, handed over per frame (`master`): the stabilization values are static here
    fn is_keyframed(&self, _: Params) -> bool { false }
    fn get_keyframes(&self, _: Params) -> Vec<(TimeType, f64)> { Vec::new() }
    fn clear_keyframes(&mut self, _: Params) -> PluginResult<()> { Ok(()) }
    fn set_f64_at_time(&mut self, p: Params, _: TimeType, v: f64) -> PluginResult<()> { self.set_f64(p, v) }
}

static BASE: LazyLock<Mutex<GyroflowPluginBase>> = LazyLock::new(|| {
    let mut base = GyroflowPluginBase::default();
    base.initialize_log("fxplug");
    base.initialize_gpu_context();
    Mutex::new(base)
});

/// One effect instance: its panel and its stabilizations
pub struct MMStab { params: MemParams, plugin: GyroflowPluginBaseInstance }

fn cstr(s: *const c_char) -> String { if s.is_null() { String::new() } else { unsafe { CStr::from_ptr(s) }.to_string_lossy().into_owned() } }
fn copy_out(s: &str, buf: *mut c_char, len: usize) -> usize {
    if !buf.is_null() && len > 0 {
        let n = s.len().min(len - 1);
        unsafe { std::ptr::copy_nonoverlapping(s.as_ptr(), buf as *mut u8, n); *buf.add(n) = 0; }
    }
    s.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_new() -> *mut MMStab {
    let base = BASE.lock();
    drop(base);
    let mut s = MMStab { params: MemParams::new(), plugin: GyroflowPluginBaseInstance::default() };
    // As Gyroflow Toolbox (Gyroflow's own Final Cut plugin) sets it for Final Cut's Metal textures: with false the
    // vertical and roll corrections go the wrong way
    s.plugin.framebuffer_inverted = true;
    s.plugin.cache_keyframes_every_frame = false;
    // One id for every instance: the effects on the same clip share its loaded stabilization (the manager cache is by
    // file and id), as the copies of an OpenFX effect do; an instance whose values differ forks it (see `detach`)
    let mut id = String::from("fcp");
    s.plugin.initialize_instance_id(&mut id);
    let _ = s.params.set_string(Params::InstanceId, &id);
    Box::into_raw(Box::new(s))
}

#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_free(s: *mut MMStab) { if !s.is_null() { drop(unsafe { Box::from_raw(s) }); } }

/// The clip's original file. Returns 1 when it changed (the clip is read again on the next render)
#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_set_file(s: *mut MMStab, path: *const c_char) -> i32 {
    let s = unsafe { &mut *s };
    let path = cstr(path);
    if s.params.get_string(Params::ProjectPath).unwrap_or_default() == path { return 0; }
    let _ = s.params.set_string(Params::ProjectPath, &path);
    let base = BASE.lock();
    let _ = s.plugin.param_changed(&mut s.params, &base.manager_cache, Params::ProjectPath, false);
    1
}

/// Sets a parameter of the panel by its OpenFX name (Mode, ZoomLimit, Smoothness, HorizonLockAmount, ...), as a user
/// edit when it changes. Returns 1 when it changed
#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_set(s: *mut MMStab, name: *const c_char, value: f64) -> i32 {
    let s = unsafe { &mut *s };
    let Ok(p) = cstr(name).parse::<Params>() else { return 0; };
    let changed = match s.params.values.get(&p) {
        Some(Value::I(v)) => { let n = value.round() as i32; if *v == n { false } else { let _ = s.params.set_i32(p, n); true } }
        Some(Value::B(v)) => { let n = value != 0.0; if *v == n { false } else { let _ = s.params.set_bool(p, n); true } }
        Some(Value::F(v)) => { if (*v - value).abs() < 1e-9 { false } else { let _ = s.params.set_f64(p, value); true } }
        _ => false,
    };
    if changed {
        let base = BASE.lock();
        if let Err(e) = s.plugin.param_changed(&mut s.params, &base.manager_cache, p, true) { log::warn!("param_changed {p:?}: {e:?}"); }
    }
    changed as i32
}

/// A parameter's current value (the mode changes Smoothness and HorizonLockAmount, which the FxPlug shows)
#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_get(s: *const MMStab, name: *const c_char) -> f64 {
    let s = unsafe { &*s };
    let Ok(p) = cstr(name).parse::<Params>() else { return 0.0; };
    match s.params.values.get(&p) { Some(Value::F(v)) => *v, Some(Value::I(v)) => *v as f64, Some(Value::B(v)) => *v as i32 as f64, _ => 0.0 }
}

/// A text of the panel: Status, ClipReport, LoadedLens...
#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_text(s: *const MMStab, name: *const c_char, buf: *mut c_char, len: usize) -> usize {
    let s = unsafe { &*s };
    let text = cstr(name).parse::<Params>().ok().and_then(|p| s.params.get_string(p).ok()).unwrap_or_default();
    copy_out(&text, buf, len)
}

/// Frame rate and frame count of the loaded clip (0 before it's loaded)
#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_clip_info(s: *const MMStab, fps: *mut f64, frames: *mut i64) {
    let s = unsafe { &*s };
    unsafe { *fps = s.plugin.fps; *frames = s.plugin.num_frames as i64; }
}

/// One render thread for every instance: the core keeps its GPU context per thread (`CACHED_WGPU`), and Final Cut renders
/// on many threads, each of which would set one up again (seconds each)
type Job = Box<dyn FnOnce() + Send>;
static WORKER: LazyLock<Mutex<std::sync::mpsc::Sender<Job>>> = LazyLock::new(|| {
    let (tx, rx) = std::sync::mpsc::channel::<Job>();
    std::thread::Builder::new().name("mecena-render".into()).spawn(move || { for job in rx { job(); } }).expect("render thread");
    Mutex::new(tx)
});
fn on_worker<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> Option<R> {
    let (tx, rx) = std::sync::mpsc::channel();
    WORKER.lock().send(Box::new(move || { let _ = tx.send(f()); })).ok()?;
    rx.recv().ok()
}
/// A pointer handed to the render thread; the caller waits for it, and holds the instance's lock meanwhile
#[derive(Clone, Copy)] struct Ptr(usize);

/// Renders the stabilized frame at `frame` of the clip (its own frame rate) from `input` into `output`, on `queue` (an
/// MTLCommandQueue): two MTLTextures when `textures`, else two MTLBuffers with their row bytes, of `width` x `height` RGBA
/// pixels (16-bit float when `half`, else 32-bit float). Returns 0 when done, otherwise an error (the caller copies the
/// input instead)
#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_render(s: *mut MMStab, frame: i64, master: f64, input: *mut c_void, in_stride: usize, output: *mut c_void, out_stride: usize,
                                 queue: *mut c_void, width: usize, height: usize, half: i32, textures: i32) -> i32 {
    let (s, input, output, queue) = (Ptr(s as usize), Ptr(input as usize), Ptr(output as usize), Ptr(queue as usize));
    on_worker(move || {
        let s = unsafe { &mut *(s.0 as *mut MMStab) };
        render(s, frame, master, input.0 as *mut c_void, in_stride, output.0 as *mut c_void, out_stride, queue.0 as *mut c_void, width, height, half != 0, textures != 0)
    }).unwrap_or(5)
}

fn render(s: &mut MMStab, frame: i64, master: f64, input: *mut c_void, in_stride: usize, output: *mut c_void, out_stride: usize,
          queue: *mut c_void, width: usize, height: usize, half: bool, textures: bool) -> i32 {
    let base = BASE.lock();
    let stab: Arc<StabilizationManager> = match s.plugin.stab_manager(&mut s.params, &base.manager_cache, (width, height), false) {
        Ok(x) => x,
        Err(e) => { log::warn!("stab_manager: {e:?}"); return 1; }
    };
    drop(base);
    let (fps, has_gyro) = { (stab.params.read().fps, !stab.gyro.read().quaternions.is_empty()) };
    if !has_gyro {
        s.plugin.set_status(&mut s.params, "Gyro assente", "La clip non ha dati di movimento leggibili.", false);
        return 2;
    }
    s.plugin.set_status(&mut s.params, "OK", "OK", true);
    if fps <= 0.0 { return 3; }
    let timestamp_us = (frame as f64 * 1_000_000.0 / fps).round() as i64;
    GyroflowPluginBaseInstance::ensure_output_aspect(&stab, (width, height));
    let source = |p: *mut c_void| if textures { BufferSource::Metal { texture: p, command_queue: queue } } else { BufferSource::MetalBuffer { buffer: p, command_queue: queue } };
    let mut buffers = Buffers {
        // Final Cut hands a different texture of its pool each frame: copied on the GPU into the core's own, its GPU state is set up once (bound directly, every new texture would set it up again)
        input:  BufferDescription { size: (width, height, in_stride),  rect: None, data: source(input),  rotation: None, texture_copy: textures },
        output: BufferDescription { size: (width, height, out_stride), rect: None, data: source(output), rotation: None, texture_copy: textures },
    };
    let master = master.clamp(0.0, 1.0);
    let started = std::time::Instant::now();
    let done = if half { stab.process_pixels_with_master::<RGBAf16>(timestamp_us, None, &mut buffers, master) }
               else    { stab.process_pixels_with_master::<RGBAf>  (timestamp_us, None, &mut buffers, master) };
    if frame % 50 == 0 { log::info!("frame {frame}: {:.1} ms", started.elapsed().as_secs_f64() * 1000.0); }
    match done { Ok(_) => 0, Err(e) => { log::warn!("render: {e:?}"); 4 } }
}

/// Smoothness and horizon lock (%) of `mode` (Resolve's table, `GyroflowPluginBase::mode_values`). Returns 0 for
/// Personalizzata, which keeps the sliders
#[unsafe(no_mangle)]
pub extern "C" fn mm_mode_values(mode: i32, smoothness: *mut f64, horizon: *mut f64) -> i32 {
    match GyroflowPluginBase::mode_values(mode) {
        Some((s, h)) => { unsafe { *smoothness = s; *horizon = h; } 1 }
        None => 0,
    }
}

/// Diagnostics: loads the clip as a render would, then measures over its frames how much the camera shakes before and
/// after the stabilization (mean angular step between frames, degrees), how far the correction turns the view (mean and
/// max, degrees) and the zoom it needs (max). Writes a line of text to `buf`
#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_probe(s: *mut MMStab, width: usize, height: usize, buf: *mut c_char, len: usize) -> usize {
    let s = unsafe { &mut *s };
    let base = BASE.lock();
    let stab = match s.plugin.stab_manager(&mut s.params, &base.manager_cache, (width, height), false) {
        Ok(x) => x,
        Err(e) => return copy_out(&format!("errore: {e:?}"), buf, len),
    };
    drop(base);
    stab.recompute_blocking();
    let (fps, frames) = { let p = stab.params.read(); (p.fps, p.frame_count) };
    let gyro = stab.gyro.read();
    let (mut raw, mut smooth, mut corr, mut corr_max, mut n) = (0.0, 0.0, 0.0, 0.0f64, 0usize);
    let mut prev: Option<(_, _)> = None;
    let mut per_sec: Vec<f64> = Vec::new();
    for f in 0..frames {
        let t = f as f64 * 1000.0 / fps;
        let (o, sm) = (gyro.org_quat_at_frame(f, t), gyro.smoothed_quat_at_frame(f, t));
        let c = o.angle_to(&sm).to_degrees();
        corr += c; corr_max = corr_max.max(c);
        if let Some((po, ps)) = prev {
            let po: gyroflow_core::gyro_source::Quat64 = po; let ps: gyroflow_core::gyro_source::Quat64 = ps;
            raw += po.angle_to(&o).to_degrees();
            let sec = (f as f64 / fps) as usize;
            if per_sec.len() <= sec { per_sec.resize(sec + 1, 0.0); }
            per_sec[sec] += po.angle_to(&o).to_degrees();
            // the path the view follows after the stabilization, frame to frame
            smooth += ps.angle_to(&sm).to_degrees();
            n += 1;
        }
        prev = Some((o, sm));
    }
    let fovs = stab.params.read().fovs.clone();
    let zoom = fovs.iter().cloned().fold(0.0f64, f64::max);
    let mut top: Vec<(usize, f64)> = per_sec.iter().cloned().enumerate().collect();
    top.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    let top = top.iter().take(6).map(|(s, v)| format!("{s}s:{v:.1}°")).collect::<Vec<_>>().join(" ");
    let line = format!("secondi più mossi {top} | frames {frames} @ {fps:.3} | movimento camera {:.4}°/fotogramma | percorso stabilizzato {:.4}°/fotogramma | correzione media {:.3}° max {:.3}° | fov max {zoom:.3} | algoritmo {}",
        raw / n.max(1) as f64, smooth / n.max(1) as f64, corr / frames.max(1) as f64, corr_max, stab.smoothing.read().current().get_name());
    copy_out(&line, buf, len)
}

/// Diagnostics: stabilizes one RGBA8 frame in memory (CPU), `inverted` as the rows' order (OpenFX's bottom-up = 1)
#[unsafe(no_mangle)]
pub extern "C" fn mm_stab_cpu_frame(s: *mut MMStab, frame: i64, inverted: i32, input: *mut u8, output: *mut u8, width: usize, height: usize) -> i32 {
    let s = unsafe { &mut *s };
    s.plugin.framebuffer_inverted = inverted != 0;
    let base = BASE.lock();
    let stab = match s.plugin.stab_manager(&mut s.params, &base.manager_cache, (width, height), false) { Ok(x) => x, Err(_) => return 1 };
    drop(base);
    stab.params.write().framebuffer_inverted = inverted != 0;
    let fps = stab.params.read().fps;
    GyroflowPluginBaseInstance::ensure_output_aspect(&stab, (width, height));
    let n = width * height * 4;
    let (inb, outb) = unsafe { (std::slice::from_raw_parts_mut(input, n), std::slice::from_raw_parts_mut(output, n)) };
    let mut buffers = Buffers {
        input:  BufferDescription { size: (width, height, width * 4), rect: None, data: BufferSource::Cpu { buffer: inb },  rotation: None, texture_copy: false },
        output: BufferDescription { size: (width, height, width * 4), rect: None, data: BufferSource::Cpu { buffer: outb }, rotation: None, texture_copy: false },
    };
    let ts = (frame as f64 * 1_000_000.0 / fps).round() as i64;
    match stab.process_pixels_with_master::<RGBA8>(ts, None, &mut buffers, 1.0) { Ok(_) => 0, Err(e) => { eprintln!("{e:?}"); 4 } }
}
