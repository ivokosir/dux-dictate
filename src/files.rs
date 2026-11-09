//! Every take is just files with one shared name, in ~/Music/Dictations:
//!
//!   2026-11-09_14-31-02.ogg         the audio (written while you talk)
//!   2026-11-09_14-31-02.txt         the transcript (missing = not transcribed)
//!   2026-11-09_14-31-02.clean.txt   the cleaned-up transcript (optional)
//!
//! There is no other state: the Recent list is whatever is in the folder.

use std::{
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use anyhow::{Context, Result, bail};
use serde::Serialize;

pub fn dir() -> PathBuf {
    if let Ok(dir) = std::env::var("DICTATE_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    // XDG music folder, next to Meeting Recorder's ~/Music/Meetings.
    let music = Command::new("xdg-user-dir")
        .arg("MUSIC")
        .stderr(Stdio::null())
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .filter(|s| !s.is_empty() && Path::new(s) != crate::home())
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::home().join("Music"));
    music.join("Dictations")
}

/// A name for a new take: local date and time, made unique within the second.
pub fn new_stamp(dir: &Path) -> String {
    let base = local_stamp();
    let mut stamp = base.clone();
    let mut n = 2;
    while audio(dir, &stamp).exists() {
        stamp = format!("{base}-{n}");
        n += 1;
    }
    stamp
}

fn local_stamp() -> String {
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        format!(
            "{:04}-{:02}-{:02}_{:02}-{:02}-{:02}",
            tm.tm_year + 1900,
            tm.tm_mon + 1,
            tm.tm_mday,
            tm.tm_hour,
            tm.tm_min,
            tm.tm_sec
        )
    }
}

/// Stamps come from the UI on the command line: only allow our own shape.
pub fn check_stamp(stamp: &str) -> Result<&str> {
    let ok = !stamp.is_empty()
        && stamp.len() <= 40
        && stamp.bytes().all(|b| b.is_ascii_digit() || b == b'-' || b == b'_');
    if !ok {
        bail!("not a take name: {stamp}");
    }
    Ok(stamp)
}

pub fn audio(dir: &Path, stamp: &str) -> PathBuf {
    dir.join(format!("{stamp}.ogg"))
}
pub fn raw(dir: &Path, stamp: &str) -> PathBuf {
    dir.join(format!("{stamp}.txt"))
}
pub fn clean(dir: &Path, stamp: &str) -> PathBuf {
    dir.join(format!("{stamp}.clean.txt"))
}

/// Writes through a temp file so a half-written transcript never shows up.
pub fn write_text(path: &Path, text: &str) -> Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, format!("{}\n", text.trim()))?;
    std::fs::rename(&tmp, path)?;
    Ok(())
}

pub fn read_text(path: &Path) -> Option<String> {
    std::fs::read_to_string(path).ok().map(|s| s.trim().to_owned())
}

#[derive(Serialize)]
pub struct Item {
    stamp: String,
    /// Raw transcript, or "" when not transcribed yet.
    text: String,
    /// Cleaned transcript, or "".
    clean: String,
    transcribed: bool,
    cleaned: bool,
    secs: f64,
}

/// All takes, newest first (stamps sort by time).
pub fn stamps(dir: &Path) -> Vec<String> {
    let mut out: Vec<String> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            let stamp = name.strip_suffix(".ogg")?;
            check_stamp(stamp).ok().map(str::to_owned)
        })
        .collect();
    out.sort_unstable_by(|a, b| b.cmp(a));
    out
}

pub fn list(dir: &Path, n: usize) -> Vec<Item> {
    // Only the start of each text is needed for the list.
    let preview = |p: PathBuf| -> String {
        read_text(&p).map(|s| s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(240).collect()).unwrap_or_default()
    };
    stamps(dir)
        .into_iter()
        .take(if n == 0 { usize::MAX } else { n })
        .map(|stamp| {
            let transcribed = raw(dir, &stamp).exists();
            let cleaned = clean(dir, &stamp).exists();
            Item {
                text: preview(raw(dir, &stamp)),
                clean: preview(clean(dir, &stamp)),
                transcribed,
                cleaned,
                secs: ogg_seconds(&audio(dir, &stamp)).unwrap_or(0.0),
                stamp,
            }
        })
        .collect()
}

/// Length of an Ogg Opus file from its last page, without decoding anything.
pub fn ogg_seconds(path: &Path) -> Option<f64> {
    let mut f = std::fs::File::open(path).ok()?;
    let mut head = [0u8; 256];
    let n = f.read(&mut head).ok()?;
    let pre_skip = head[..n]
        .windows(8)
        .position(|w| w == b"OpusHead")
        .and_then(|i| head.get(i + 10..i + 12))
        .map(|b| u16::from_le_bytes([b[0], b[1]]) as i64)
        .unwrap_or(0);
    let len = f.metadata().ok()?.len();
    let back = len.min(65_536);
    f.seek(SeekFrom::Start(len - back)).ok()?;
    let mut tail = Vec::with_capacity(back as usize);
    f.read_to_end(&mut tail).ok()?;
    let at = tail.windows(4).rposition(|w| w == b"OggS")?;
    let g = tail.get(at + 6..at + 14)?;
    let granule = i64::from_le_bytes(g.try_into().ok()?);
    (granule > 0).then(|| (granule - pre_skip).max(0) as f64 / 48_000.0)
}

/// Moves a take's files to the trash (so it can be undone).
pub fn trash(dir: &Path, stamp: &str) -> Result<()> {
    let files: Vec<PathBuf> =
        [audio(dir, stamp), raw(dir, stamp), clean(dir, stamp)].into_iter().filter(|p| p.exists()).collect();
    if files.is_empty() {
        return Ok(());
    }
    let status = Command::new("gio")
        .arg("trash")
        .args(&files)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("could not run gio trash")?;
    if !status.success() {
        bail!("gio trash failed");
    }
    Ok(())
}

/// Keeps the newest `keep` takes; older ones go to the trash.
pub fn prune(dir: &Path, keep: usize, except: &str) {
    for stamp in stamps(dir).into_iter().filter(|s| s != except).skip(keep) {
        if let Err(error) = trash(dir, &stamp) {
            eprintln!("dictate: could not tidy up {stamp}: {error:#}");
        }
    }
}

/// Shows the file selected in the file manager (or just opens the folder).
pub fn reveal(path: &Path) {
    let uri = format!("file://{}", percent_path(path));
    let shown = Command::new("busctl")
        .args([
            "--user",
            "call",
            "org.freedesktop.FileManager1",
            "/org/freedesktop/FileManager1",
            "org.freedesktop.FileManager1",
            "ShowItems",
            "ass",
            "1",
            &uri,
            "",
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !shown {
        open(path.parent().unwrap_or(path));
    }
}

pub fn open(path: &Path) {
    let _ = Command::new("setsid")
        .arg("-f")
        .arg("xdg-open")
        .arg(path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn percent_path(path: &Path) -> String {
    let mut out = String::new();
    for b in path.to_string_lossy().bytes() {
        if b.is_ascii_alphanumeric() || b"/-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}
