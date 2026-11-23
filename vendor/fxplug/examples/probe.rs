// SPDX-License-Identifier: GPL-3.0-or-later
// cargo run --example probe -- FILE [MODE] [ZOOM]: how much Mecena Stabilize corrects the clip (see mm_stab_probe)
use std::ffi::{ CStr, CString };
use mecena_fxplug as _;
unsafe extern "C" {
    fn mm_stab_new() -> *mut std::ffi::c_void;
    fn mm_stab_set_file(s: *mut std::ffi::c_void, path: *const std::ffi::c_char) -> i32;
    fn mm_stab_set(s: *mut std::ffi::c_void, name: *const std::ffi::c_char, value: f64) -> i32;
    fn mm_stab_probe(s: *mut std::ffi::c_void, w: usize, h: usize, buf: *mut std::ffi::c_char, len: usize) -> usize;
}
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = CString::new(args[1].clone()).unwrap();
    unsafe {
        let s = mm_stab_new();
        mm_stab_set_file(s, path.as_ptr());
        for mode in args.get(2).filter(|m| !m.is_empty()).map(|m| vec![m.parse::<f64>().unwrap()]).unwrap_or(vec![0.0, 1.0, 2.0, 3.0, 4.0]) {
            for zoom in args.get(3).map(|z| vec![z.parse::<f64>().unwrap()]).unwrap_or(vec![130.0, 200.0]) {
                mm_stab_set(s, c"Mode".as_ptr(), mode);
                mm_stab_set(s, c"ZoomLimit".as_ptr(), zoom);
                let mut buf = vec![0 as std::ffi::c_char; 1024];
                mm_stab_probe(s, 3840, 2160, buf.as_mut_ptr(), buf.len());
                println!("modo {mode} zoom {zoom}: {}", CStr::from_ptr(buf.as_ptr()).to_string_lossy());
            }
        }
    }
}
