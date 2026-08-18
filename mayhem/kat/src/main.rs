//! mp4parse-mayhem-kat — the known-answer probe used by mayhem/test.sh.
//!
//! Why this exists (SPEC §6.3 / docs/netnew-worker-prompt.md §4): `cargo test` alone is
//! explicitly FORBIDDEN as the sole oracle — it proves only upstream's own dev-dependency
//! assertions, and the spec wants a small, purpose-built, independently-verifiable, DYNAMICALLY
//! LINKED binary the verify-repo sabotage shim can neuter. This probe:
//!
//!   1. Parses THREE fixed real-world media fixtures — embedded into the binary at compile time
//!      via `include_bytes!` (no filesystem access at runtime at all: not cwd-relative, not an
//!      absolute image path) — through mp4parse_capi's real public C API, the same API the
//!      upstream fuzz targets (mp4parse_capi/fuzz/fuzz_targets/{mp4,avif}.rs) drive.
//!   2. Asserts each parsed field is EXACTLY the expected value (panics -> nonzero exit
//!      otherwise).
//!   3. Prints `KAT_<NAME>=<value>` lines that mayhem/test.sh matches with `grep -qxF`.
//!
//! A neutered binary (verify-repo's LD_PRELOAD shim `_exit(0)`s it before any of this runs)
//! prints nothing, so every `grep -qxF` in test.sh fails — the oracle is behavioral, not
//! exit-code-only.
//!
//! Expected values below are lifted directly from upstream's own known-answer tests:
//!   - mp4parse_capi/tests/test_rotation.rs::parse_rotation (video_rotation_90.mp4)
//!   - mp4parse_capi/tests/test_xhe_aac.rs::test_xhe_aac_codec_detection (sine-3s-xhe-aac-44khz-mono.mp4)
//!   - mp4parse_capi/tests/test_avis.rs::check_timescales (no_edts.avif -> timescale 16384)
//! and independently confirmed by running this probe against the real parser.
use mp4parse_capi::*;
use std::io::{Cursor, Read};
use std::mem::MaybeUninit;
use std::os::raw::c_void;

type CursorType<'a> = Cursor<&'a [u8]>;

extern "C" fn cursor_read(buf: *mut u8, size: usize, userdata: *mut c_void) -> isize {
    let input: &mut CursorType = unsafe { &mut *(userdata as *mut _) };
    let buf = unsafe { std::slice::from_raw_parts_mut(buf, size) };
    match input.read(buf) {
        Ok(n) => n as isize,
        Err(_) => -1,
    }
}

/// Fixed fixture: a single video track rotated 90 degrees (upstream's own
/// `test_rotation.rs::parse_rotation`, shipped as one of our own starter seeds).
const ROTATION_MP4: &[u8] = include_bytes!("../../mp4/testsuite/video_rotation_90.mp4");
/// Fixed fixture: a single xHE-AAC audio track (upstream's own
/// `test_xhe_aac.rs::test_xhe_aac_codec_detection`).
const XHEAAC_MP4: &[u8] = include_bytes!("../../mp4/testsuite/sine-3s-xhe-aac-44khz-mono.mp4");
/// Fixed fixture: an AVIF still image with no `elst` (upstream's own
/// `test_avis.rs::{no_edts,check_timescales}`).
const NO_EDTS_AVIF: &[u8] = include_bytes!("../../avif/testsuite/no_edts.avif");

fn kat_rotation() {
    let mut cursor: CursorType = Cursor::new(ROTATION_MP4);
    let io = Mp4parseIo {
        read: Some(cursor_read),
        userdata: &mut cursor as *mut CursorType as *mut c_void,
    };
    unsafe {
        let mut parser = std::ptr::null_mut();
        let rv = mp4parse_new(&io, &mut parser);
        assert_eq!(rv, Mp4parseStatus::Ok, "KAT_ROTATION: mp4parse_new failed");
        assert!(!parser.is_null());

        let mut count: u32 = 0;
        let rv = mp4parse_get_track_count(parser, &mut count);
        assert_eq!(rv, Mp4parseStatus::Ok);
        assert_eq!(count, 1, "KAT_ROTATION: expected exactly one track");

        let mut video = Mp4parseTrackVideoInfo::default();
        let rv = mp4parse_get_track_video_info(parser, 0, &mut video);
        assert_eq!(rv, Mp4parseStatus::Ok);
        assert_eq!(video.rotation, 90, "KAT_ROTATION: expected 90 degree rotation");

        mp4parse_free(parser);
        println!("KAT_ROTATION={}", video.rotation);
    }
}

fn kat_xheaac_track_type() {
    let mut cursor: CursorType = Cursor::new(XHEAAC_MP4);
    let io = Mp4parseIo {
        read: Some(cursor_read),
        userdata: &mut cursor as *mut CursorType as *mut c_void,
    };
    unsafe {
        let mut parser = std::ptr::null_mut();
        let rv = mp4parse_new(&io, &mut parser);
        assert_eq!(rv, Mp4parseStatus::Ok, "KAT_XHEAAC: mp4parse_new failed");
        assert!(!parser.is_null());

        let mut count: u32 = 0;
        let rv = mp4parse_get_track_count(parser, &mut count);
        assert_eq!(rv, Mp4parseStatus::Ok);
        assert_eq!(count, 1, "KAT_XHEAAC: expected exactly one track");

        let mut info = Mp4parseTrackInfo::default();
        let rv = mp4parse_get_track_info(parser, 0, &mut info);
        assert_eq!(rv, Mp4parseStatus::Ok);
        assert_eq!(
            info.track_type,
            Mp4parseTrackType::Audio,
            "KAT_XHEAAC: expected an audio track"
        );

        mp4parse_free(parser);
        println!("KAT_XHEAAC_TRACK_TYPE={:?}", info.track_type);
    }
}

fn kat_avif_timescale() {
    let mut cursor: CursorType = Cursor::new(NO_EDTS_AVIF);
    let io = Mp4parseIo {
        read: Some(cursor_read),
        userdata: &mut cursor as *mut CursorType as *mut c_void,
    };
    unsafe {
        let mut parser = std::ptr::null_mut();
        let rv = mp4parse_avif_new(&io, ParseStrictness::Normal, &mut parser);
        assert_eq!(rv, Mp4parseStatus::Ok, "KAT_AVIF_TIMESCALE: mp4parse_avif_new failed");
        assert!(!parser.is_null());

        let mut info = MaybeUninit::zeroed();
        let rv = mp4parse_avif_get_info(&*parser, info.as_mut_ptr());
        assert_eq!(rv, Mp4parseStatus::Ok);
        let info = info.assume_init();

        let mut indices = Mp4parseByteData::default();
        let mut timescale: u64 = 0;
        let rv =
            mp4parse_avif_get_indice_table(parser, info.color_track_id, &mut indices, &mut timescale);
        assert_eq!(rv, Mp4parseStatus::Ok);
        assert_eq!(timescale, 16384, "KAT_AVIF_TIMESCALE: expected timescale 16384");

        mp4parse_avif_free(parser);
        println!("KAT_AVIF_TIMESCALE={}", timescale);
    }
}

fn main() {
    kat_rotation();
    kat_xheaac_track_type();
    kat_avif_timescale();
}
