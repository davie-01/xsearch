//! Minimal M0 C ABI. Swift calls the canonical versioned normalizer instead of OS-dependent folding.
use crate::normalize::{Mode, normalize};
use std::{
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
};
/// # Safety
/// `input` must reference `len` readable bytes. The caller must release the result once with
/// `xs_string_free`. Invalid UTF-8/mode or a caught panic returns null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xs_normalize_utf8(input: *const u8, len: usize, mode: u8) -> *mut c_char {
    if input.is_null() {
        return std::ptr::null_mut();
    }
    catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(input, len) };
        let text = std::str::from_utf8(bytes).ok()?;
        let mode = match mode {
            0 => Mode::Loose,
            1 => Mode::CaseSensitive,
            2 => Mode::Strict,
            _ => return None,
        };
        let json = serde_json::to_string(&normalize(text, mode)).ok()?;
        Some(CString::new(json).ok()?.into_raw())
    }))
    .ok()
    .flatten()
    .unwrap_or(std::ptr::null_mut())
}
/// # Safety
/// `value` is null or an unreleased pointer returned by `xs_normalize_utf8`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xs_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
/// Version of `crate::query::name_key`; persisted name snapshots must be rebuilt when it changes.
pub const NAME_KEY_VERSION: &str = "xs-name-nfc-ucd17-fullfold-nfc-v1\0";
#[unsafe(no_mangle)]
pub extern "C" fn xs_name_key_version() -> *const c_char {
    NAME_KEY_VERSION.as_ptr().cast()
}
/// Writes the NFC/full-fold name key into `out` and returns its byte length. If `out_cap` is too
/// small nothing is written and the required length is still returned, so the caller can retry.
/// Returns -1 for null input, invalid UTF-8 or a caught panic.
///
/// # Safety
/// `input` must reference `len` readable bytes; `out` must reference `out_cap` writable bytes
/// (it may be null when `out_cap` is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn xs_name_key(
    input: *const u8,
    len: usize,
    out: *mut u8,
    out_cap: usize,
) -> isize {
    if input.is_null() {
        return -1;
    }
    catch_unwind(AssertUnwindSafe(|| {
        let bytes = unsafe { std::slice::from_raw_parts(input, len) };
        let key = crate::query::name_key(std::str::from_utf8(bytes).ok()?);
        if key.len() <= out_cap && !out.is_null() {
            unsafe { std::ptr::copy_nonoverlapping(key.as_ptr(), out, key.len()) };
        }
        isize::try_from(key.len()).ok()
    }))
    .ok()
    .flatten()
    .unwrap_or(-1)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn key(s: &str) -> Option<String> {
        let mut buf = vec![0u8; 4];
        let n = unsafe { xs_name_key(s.as_ptr(), s.len(), buf.as_mut_ptr(), buf.len()) };
        let n = usize::try_from(n).ok()?;
        if n > buf.len() {
            buf.resize(n, 0);
            assert_eq!(
                unsafe { xs_name_key(s.as_ptr(), s.len(), buf.as_mut_ptr(), buf.len()) },
                n as isize
            );
        }
        buf.truncate(n);
        String::from_utf8(buf).ok()
    }
    #[test]
    fn name_key_abi_matches_rust_and_rejects_invalid_utf8() {
        for s in [
            "Straße.TXT",
            "cafe\u{301}",
            "数据共享方案.docx",
            "",
            "ＡＢＣ",
        ] {
            assert_eq!(key(s).as_deref(), Some(crate::query::name_key(s).as_str()));
        }
        assert_eq!(key("cafe\u{301}").as_deref(), Some("café"));
        let bad = [0xffu8, 0xfe];
        assert_eq!(
            unsafe { xs_name_key(bad.as_ptr(), 2, std::ptr::null_mut(), 0) },
            -1
        );
        assert!(!xs_name_key_version().is_null());
    }
}
