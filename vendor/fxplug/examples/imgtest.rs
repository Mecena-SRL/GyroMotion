// SPDX-License-Identifier: GPL-3.0-or-later
// ffmpeg ... -f rawvideo -pix_fmt rgba - | imgtest FILE FIRST COUNT W H MODE: global image motion between consecutive frames,
// of the clip and of the stabilized clip with the rows top-down (0) and bottom-up (1). The right orientation moves less
use std::ffi::CString;
use std::io::Read;
use mecena_fxplug as _;
unsafe extern "C" {
    fn mm_stab_new() -> *mut std::ffi::c_void;
    fn mm_stab_set_file(s: *mut std::ffi::c_void, path: *const std::ffi::c_char) -> i32;
    fn mm_stab_set(s: *mut std::ffi::c_void, name: *const std::ffi::c_char, value: f64) -> i32;
    fn mm_stab_cpu_frame(s: *mut std::ffi::c_void, frame: i64, inverted: i32, input: *mut u8, output: *mut u8, w: usize, h: usize) -> i32;
}
/// Grey, 4x smaller
fn small(rgba: &[u8], w: usize, h: usize) -> (Vec<f32>, usize, usize) {
    let (sw, sh) = (w / 4, h / 4);
    let mut g = vec![0f32; sw * sh];
    for y in 0..sh { for x in 0..sw {
        let mut acc = 0f32;
        for dy in 0..4 { for dx in 0..4 { let i = ((y * 4 + dy) * w + x * 4 + dx) * 4; acc += rgba[i] as f32 + rgba[i + 1] as f32 + rgba[i + 2] as f32; } }
        g[y * sw + x] = acc / 48.0;
    } }
    (g, sw, sh)
}
/// The shift (pixels of the small image) that best matches b to a, within ±r, centre region only
fn shift(a: &[f32], b: &[f32], w: usize, h: usize, r: i32) -> (i32, i32) {
    let (mut best, mut bx, mut by) = (f32::MAX, 0, 0);
    let m = (r + w as i32 / 6) as usize;
    let mh = (r + h as i32 / 6) as usize;
    for dy in -r..=r { for dx in -r..=r {
        let mut sad = 0f32;
        for y in (mh..h - mh).step_by(2) { for x in (m..w - m).step_by(2) {
            sad += (a[y * w + x] - b[(y as i32 + dy) as usize * w + (x as i32 + dx) as usize]).abs();
        } }
        if sad < best { best = sad; bx = dx; by = dy; }
    } }
    (bx, by)
}
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (first, count, w, h): (i64, usize, usize, usize) = (a[2].parse().unwrap(), a[3].parse().unwrap(), a[4].parse().unwrap(), a[5].parse().unwrap());
    let mode: f64 = a[6].parse().unwrap();
    let path = CString::new(a[1].clone()).unwrap();
    let mut frames = Vec::new();
    let mut stdin = std::io::stdin();
    for _ in 0..count { let mut f = vec![0u8; w * h * 4]; if stdin.read_exact(&mut f).is_err() { break; } frames.push(f); }
    unsafe {
        let s = mm_stab_new();
        mm_stab_set_file(s, path.as_ptr());
        mm_stab_set(s, c"Mode".as_ptr(), mode);
        let mut results = Vec::new();
        for label in ["originale", "top-down (0)", "bottom-up (1)"] {
            let mut prev: Option<Vec<f32>> = None;
            let (mut sx, mut sy, mut n) = (0f64, 0f64, 0);
            for (i, f) in frames.iter().enumerate() {
                let img = if label == "originale" { f.clone() } else {
                    let mut inp = f.clone(); let mut out = vec![0u8; w * h * 4];
                    let inv = if label.starts_with("top") { 0 } else { 1 };
                    if mm_stab_cpu_frame(s, first + i as i64, inv, inp.as_mut_ptr(), out.as_mut_ptr(), w, h) != 0 { panic!("render"); }
                    out
                };
                let (g, sw, sh) = small(&img, w, h);
                if let Some(p) = &prev { let (dx, dy) = shift(p, &g, sw, sh, 6); sx += dx.abs() as f64; sy += dy.abs() as f64; n += 1; }
                prev = Some(g);
            }
            results.push(format!("{label}: spostamento medio x {:.2} y {:.2} px (su {}x{} ridotta)", sx / n as f64, sy / n as f64, w / 4, h / 4));
        }
        for r in results { println!("{r}"); }
    }
}
