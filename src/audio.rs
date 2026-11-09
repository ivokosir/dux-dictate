//! Microphone capture through PipeWire (`pw-record`), 16 kHz mono s16le.

use std::process::Stdio;

use anyhow::{Context, Result};
use tokio::{
    io::AsyncReadExt,
    process::{Child, ChildStdout, Command},
};

pub const SAMPLE_RATE: u32 = 16_000;
pub const BYTES_PER_SEC: usize = SAMPLE_RATE as usize * 2;

pub struct Recorder {
    child: Child,
    stdout: ChildStdout,
}

impl Recorder {
    pub fn start() -> Result<Self> {
        // DICTATE_TEST_AUDIO=<file> plays a file in real time instead of the mic.
        let mut command = match std::env::var("DICTATE_TEST_AUDIO") {
            Ok(file) => {
                let mut c = Command::new("ffmpeg");
                c.args(["-loglevel", "quiet", "-re", "-i", &file, "-f", "s16le", "-ar", "16000", "-ac", "1", "-"]);
                c
            }
            Err(_) => {
                let mut c = Command::new("pw-record");
                c.args(["--raw", "--rate", "16000", "--channels", "1", "--format", "s16", "--latency", "50ms", "-"]);
                c
            }
        };
        let mut child = command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("could not start pw-record (is PipeWire installed?)")?;
        let stdout = child.stdout.take().context("pw-record has no stdout")?;
        Ok(Self { child, stdout })
    }

    /// Reads the next block of audio. Returns 0 bytes when the recorder ended.
    pub async fn read(&mut self, buf: &mut [u8]) -> Result<usize> {
        Ok(self.stdout.read(buf).await?)
    }

    /// Asks pw-record to stop and returns whatever audio was still buffered.
    pub async fn finish(mut self) -> Vec<u8> {
        if let Some(pid) = self.child.id() {
            unsafe { libc::kill(pid as i32, libc::SIGINT) };
        }
        let mut rest = Vec::new();
        let _ = tokio::time::timeout(
            std::time::Duration::from_millis(400),
            self.stdout.read_to_end(&mut rest),
        )
        .await;
        let _ = self.child.start_kill();
        let _ = self.child.wait().await;
        rest
    }
}

/// Loudness of a block of s16le samples, mapped to 0..1 for the UI.
pub fn level(pcm: &[u8]) -> f32 {
    let samples = pcm.len() / 2;
    if samples == 0 {
        return 0.0;
    }
    let mut sum = 0f64;
    for pair in pcm.chunks_exact(2) {
        let s = i16::from_le_bytes([pair[0], pair[1]]) as f64 / 32768.0;
        sum += s * s;
    }
    let rms = (sum / samples as f64).sqrt();
    let db = 20.0 * rms.max(1e-9).log10();
    ((db + 55.0) / 45.0).clamp(0.0, 1.0) as f32
}

pub fn wav(pcm: &[u8]) -> Vec<u8> {
    let data_len = pcm.len() as u32;
    let mut out = Vec::with_capacity(44 + pcm.len());
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    out.extend_from_slice(&(SAMPLE_RATE * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    out.extend_from_slice(pcm);
    out
}
