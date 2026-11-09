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

/// Encodes the mic audio to Ogg Opus on disk while you talk, so a long take
/// never piles up in memory and a crash still leaves a playable file.
pub struct Encoder {
    tx: Option<tokio::sync::mpsc::UnboundedSender<Vec<u8>>>,
    task: tokio::task::JoinHandle<Result<()>>,
}

impl Encoder {
    pub fn start(path: &std::path::Path) -> Result<Self> {
        use tokio::io::AsyncWriteExt;
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).with_context(|| format!("could not create {}", dir.display()))?;
        }
        let mut child = Command::new("ffmpeg")
            .args(["-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", "16000", "-ac", "1", "-i", "pipe:0"])
            .args(["-c:a", "libopus", "-b:a", "24k", "-application", "voip", "-y"])
            .arg(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("could not start ffmpeg to save the audio")?;
        let mut stdin = child.stdin.take().context("ffmpeg has no stdin")?;
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
        // A separate writer keeps the mic loop from ever waiting on the encoder.
        let task = tokio::spawn(async move {
            while let Some(chunk) = rx.recv().await {
                stdin.write_all(&chunk).await.context("ffmpeg stopped taking audio")?;
            }
            drop(stdin);
            let status = tokio::time::timeout(std::time::Duration::from_secs(10), child.wait())
                .await
                .context("ffmpeg did not finish")??;
            anyhow::ensure!(status.success(), "ffmpeg failed ({status})");
            Ok(())
        });
        Ok(Self { tx: Some(tx), task })
    }

    pub fn write(&self, pcm: &[u8]) {
        if let Some(tx) = &self.tx {
            let _ = tx.send(pcm.to_vec());
        }
    }

    /// Closes the file and waits until it is complete on disk.
    pub async fn finish(mut self) -> Result<()> {
        self.tx.take();
        self.task.await.context("encoder task failed")?
    }
}
