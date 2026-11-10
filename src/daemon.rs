//! The background service: one recording at a time, state broadcast to the UI.
//!
//! Takes live in ~/Music/Dictations as plain files (see files.rs). The daemon
//! only keeps what is happening right now.

use std::{
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use serde::Serialize;
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    signal::unix::{SignalKind, signal},
    sync::{oneshot, watch},
    time::Instant,
};

use crate::{
    Config,
    audio::{self, BYTES_PER_SEC, Encoder, Recorder},
    eleven, files, output,
};

#[derive(Serialize, Clone, Default)]
pub struct Snapshot {
    daemon: bool,
    /// idle | recording | transcribing | cleaning | problem
    state: String,
    /// When state is "problem": cleanfail | copy | paste | nospeech | mic | eleven | nokey | other
    problem: String,
    /// Details for a problem (shown as a tooltip).
    message: String,
    /// direct | luna
    mode: String,
    started_ms: u64,
    can_retry: bool,
    configured: bool,
    /// The bar popout is open: the card steps aside, and finishing copies instead of pasting.
    popout: bool,
    /// The take being recorded or worked on (the Recent list hides it until it is done).
    current: String,
    /// Bumped whenever takes on disk change, so the popout knows to re-read the folder.
    files: u64,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Mode {
    Direct,
    Luna,
}

impl Mode {
    fn parse(s: Option<&str>) -> Option<Self> {
        match s? {
            "direct" => Some(Self::Direct),
            "luna" | "clean" => Some(Self::Luna),
            _ => None,
        }
    }
    fn name(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Luna => "luna",
        }
    }
}

/// How a finished take reaches you.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Out {
    /// Ctrl+V into the app you were in.
    Paste,
    /// Clipboard only (finished from the popout: you are not in your app).
    Copy,
}

enum Stop {
    Finish(Option<Mode>, Out),
    Cancel,
}

struct Failed {
    stamp: String,
    mode: Mode,
    out: Out,
}

#[derive(Default)]
struct Ctl {
    session: u64,
    stop: Option<oneshot::Sender<Stop>>,
    failed: Option<Failed>,
}

struct Daemon {
    snap: watch::Sender<Snapshot>,
    /// Mic loudness 0..1, sent separately so the UI doesn't re-read the whole state ~20x/s.
    level: watch::Sender<f32>,
    ctl: Mutex<Ctl>,
    /// One command at a time: two "start"s arriving together must not both see "idle".
    commands: Mutex<()>,
    config: Mutex<Config>,
    http: reqwest::Client,
    dir: PathBuf,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl Daemon {
    fn update(&self, f: impl FnOnce(&mut Snapshot)) {
        self.snap.send_modify(f);
    }

    fn state(&self) -> String {
        self.snap.borrow().state.clone()
    }

    fn is_current(&self, id: u64) -> bool {
        self.ctl.lock().unwrap().session == id
    }

    fn new_session(&self) -> u64 {
        let mut ctl = self.ctl.lock().unwrap();
        ctl.session += 1;
        ctl.stop = None;
        ctl.session
    }

    fn files_changed(&self) {
        self.update(|s| s.files += 1);
    }

    fn idle(&self, id: u64) {
        if self.is_current(id) {
            self.update(|s| {
                s.state = "idle".into();
                s.problem.clear();
                s.message.clear();
                s.current.clear();
                s.can_retry = false;
            });
        }
    }

    /// Shows a problem. Everything fades by itself; a failed take stays in Recent
    /// (with ⟳ Transcribe), so nothing needs the card to stick around.
    fn problem(self: &Arc<Self>, id: u64, code: &str, message: String, failed: Option<Failed>) {
        eprintln!("dictate: {code}: {message}");
        if !self.is_current(id) {
            return;
        }
        let can_retry = failed.is_some();
        self.ctl.lock().unwrap().failed = failed;
        let code = code.to_owned();
        let fade = match code.as_str() {
            "nospeech" => Some(3),
            "cleanfail" => Some(6),
            "paste" => Some(8),
            _ => Some(10),
        };
        self.update(|s| {
            s.state = "problem".into();
            s.problem = code;
            s.message = message;
            s.can_retry = can_retry;
            s.current.clear();
        });
        if let Some(secs) = fade {
            let d = self.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(secs)).await;
                if d.state() == "problem" {
                    d.idle(id);
                }
            });
        }
    }

    fn command(self: &Arc<Self>, line: &str) -> String {
        let _one_at_a_time = self.commands.lock().unwrap_or_else(|e| e.into_inner());
        let mut words = line.split_whitespace();
        let cmd = words.next().unwrap_or("");
        let args: Vec<&str> = words.collect();
        let mode = args.iter().find_map(|a| Mode::parse(Some(a)));
        let state = self.state();
        let busy = matches!(state.as_str(), "transcribing" | "cleaning");
        // Finishing while the popout is open (or asked for) only copies.
        let out = if args.contains(&"copy") || self.snap.borrow().popout { Out::Copy } else { Out::Paste };
        match cmd {
            "toggle" => match state.as_str() {
                "recording" => self.stop(Stop::Finish(mode, out)),
                _ if busy => {}
                _ => self.start(mode.unwrap_or(Mode::Direct)),
            },
            "start" if state != "recording" && !busy => self.start(mode.unwrap_or(Mode::Direct)),
            "stop" if state == "recording" => self.stop(Stop::Finish(mode, out)),
            "cancel" => {
                if state == "recording" {
                    self.stop(Stop::Cancel);
                } else {
                    let id = self.new_session();
                    self.idle(id);
                }
            }
            // From the popout (or with "copy") a retry only copies, like finishing does.
            "retry" if !busy && state != "recording" => self.retry((out == Out::Copy).then_some(Out::Copy)),
            "popout" => {
                let open = args.first().copied() == Some("on");
                self.update(|s| s.popout = open);
            }
            "refresh" => self.files_changed(),
            "start" | "stop" | "retry" => {}
            other => return format!("unknown command: {other}"),
        }
        "ok".into()
    }

    fn stop(&self, how: Stop) {
        if let Some(tx) = self.ctl.lock().unwrap().stop.take() {
            let _ = tx.send(how);
        }
    }

    fn start(self: &Arc<Self>, mode: Mode) {
        let (tx, rx) = oneshot::channel();
        let id = {
            let mut ctl = self.ctl.lock().unwrap();
            ctl.session += 1;
            ctl.stop = Some(tx);
            ctl.failed = None;
            ctl.session
        };
        let config = self.config.lock().unwrap().clone();
        let stamp = files::new_stamp(&self.dir);
        self.update(|s| {
            s.state = "recording".into();
            s.problem.clear();
            s.message.clear();
            s.mode = mode.name().into();
            s.started_ms = now_ms();
            s.can_retry = false;
            s.configured = crate::api_key().is_ok();
            s.current = stamp.clone();
        });
        tokio::spawn(self.clone().run(id, stamp, mode, config, rx));
    }

    async fn run(
        self: Arc<Self>,
        id: u64,
        stamp: String,
        mode: Mode,
        config: Config,
        mut stop_rx: oneshot::Receiver<Stop>,
    ) {
        let key = match crate::api_key() {
            Ok(key) => key,
            Err(error) => return self.problem(id, "nokey", error.to_string(), None),
        };
        let mut recorder = match Recorder::start() {
            Ok(r) => r,
            Err(error) => return self.problem(id, "mic", error.to_string(), None),
        };
        let ogg = files::audio(&self.dir, &stamp);
        let encoder = match Encoder::start(&ogg) {
            Ok(e) => e,
            Err(error) => return self.problem(id, "other", format!("{error:#}"), None),
        };

        let mut bytes = 0usize;
        let mut buf = vec![0u8; 4096];
        let mut window: Vec<u8> = Vec::new();
        let mut last_level = Instant::now();
        let mut mic_lost = false;

        // No time limit: the audio goes straight to disk, so long takes are fine.
        let stop = loop {
            tokio::select! {
                how = &mut stop_rx => break how.unwrap_or(Stop::Cancel),
                n = recorder.read(&mut buf) => match n {
                    Ok(n) if n > 0 => {
                        let data = &buf[..n];
                        bytes += n;
                        encoder.write(data);
                        window.extend_from_slice(data);
                        if last_level.elapsed() >= Duration::from_millis(50) {
                            let level = audio::level(&window);
                            window.clear();
                            last_level = Instant::now();
                            self.level.send_replace(level);
                        }
                    }
                    _ => {
                        mic_lost = true;
                        break Stop::Finish(None, Out::Paste);
                    }
                }
            }
        };

        let rest = recorder.finish().await;
        self.level.send_replace(0.0);
        bytes += rest.len();
        encoder.write(&rest);

        let remove_take = |d: &Daemon| {
            let _ = std::fs::remove_file(files::audio(&d.dir, &stamp));
        };
        let (final_mode, out) = match stop {
            Stop::Cancel => {
                let _ = encoder.finish().await;
                remove_take(&self);
                return self.idle(id);
            }
            Stop::Finish(m, out) => (m.unwrap_or(mode), out),
        };

        if bytes < BYTES_PER_SEC * 3 / 10 {
            let _ = encoder.finish().await;
            remove_take(&self);
            if mic_lost {
                return self.problem(id, "mic", "Could not record from the microphone".into(), None);
            }
            return self.idle(id);
        }

        self.update(|s| {
            s.state = "transcribing".into();
            s.mode = final_mode.name().into();
        });

        let saved = encoder.finish().await;
        if let Err(error) = &saved {
            eprintln!("dictate: saving the audio failed: {error:#}");
        }
        self.files_changed();

        let result = match std::fs::read(&ogg) {
            Ok(data) => eleven::transcribe(&self.http, &key, &config.language, data).await,
            Err(error) => Err(anyhow::anyhow!("the audio file is missing: {error}")),
        };
        match result {
            Ok(text) => self.deliver(id, stamp, text, final_mode, out, &config).await,
            Err(error) => {
                let failed = saved.is_ok().then(|| Failed { stamp: stamp.clone(), mode: final_mode, out });
                self.problem(id, "eleven", format!("{error:#}"), failed)
            }
        }
    }

    async fn deliver(
        self: &Arc<Self>,
        id: u64,
        stamp: String,
        text: String,
        mode: Mode,
        out: Out,
        config: &Config,
    ) {
        if !self.is_current(id) {
            return;
        }
        let mut text = text.trim().to_owned();
        if text.is_empty() {
            // Nothing was said: the audio is just silence, so drop it for good.
            let _ = std::fs::remove_file(files::audio(&self.dir, &stamp));
            self.files_changed();
            return self.problem(id, "nospeech", String::new(), None);
        }
        if let Err(error) = files::write_text(&files::raw(&self.dir, &stamp), &text) {
            eprintln!("dictate: could not save the transcript: {error:#}");
        }
        let mut clean_failed = None;
        if mode == Mode::Luna {
            self.update(|s| s.state = "cleaning".into());
            match output::luna(&config.luna_command, &text, config.luna_timeout_secs).await {
                Ok(cleaned) => {
                    let _ = files::write_text(&files::clean(&self.dir, &stamp), &cleaned);
                    text = cleaned;
                }
                Err(error) => clean_failed = Some(format!("{error:#}")),
            }
            if !self.is_current(id) {
                return;
            }
        }
        // Clipboard first; "paste" is then only the Ctrl+V. The two fail differently:
        // after a failed copy the text is NOT on the clipboard.
        let delivered: std::result::Result<(), (&str, anyhow::Error)> = async {
            output::copy(&text).await.map_err(|e| ("copy", e))?;
            if out == Out::Paste {
                output::press_paste().await.map_err(|e| ("paste", e))?;
            }
            Ok(())
        }
        .await;
        files::prune(&self.dir, config.keep, &stamp);
        self.files_changed();
        if let Err((code, error)) = delivered {
            return self.problem(id, code, format!("{error:#}"), None);
        }
        if let Some(message) = clean_failed {
            return self.problem(id, "cleanfail", message, None);
        }
        self.idle(id);
    }

    fn retry(self: &Arc<Self>, out_now: Option<Out>) {
        let Some(Failed { stamp, mode, out }) = self.ctl.lock().unwrap().failed.take() else { return };
        let out = out_now.unwrap_or(out);
        let id = self.new_session();
        let config = self.config.lock().unwrap().clone();
        self.update(|s| {
            s.state = "transcribing".into();
            s.problem.clear();
            s.message.clear();
            s.mode = mode.name().into();
            s.can_retry = false;
            s.current = stamp.clone();
        });
        let d = self.clone();
        tokio::spawn(async move {
            let result = async {
                let key = crate::api_key()?;
                let data = std::fs::read(files::audio(&d.dir, &stamp)).context("the saved recording is gone")?;
                eleven::transcribe(&d.http, &key, &config.language, data).await
            }
            .await;
            match result {
                Ok(text) => d.deliver(id, stamp, text, mode, out, &config).await,
                Err(error) => d.problem(id, "eleven", format!("{error:#}"), Some(Failed { stamp, mode, out })),
            }
        });
    }
}

async fn handle(d: Arc<Daemon>, stream: UnixStream) -> Result<()> {
    let (read, mut write) = stream.into_split();
    let mut line = String::new();
    BufReader::new(read).read_line(&mut line).await?;
    let line = line.trim();
    match line {
        "watch" => {
            // Full state as JSON on change; mic level as a tiny "L 0.420" line.
            let mut rx = d.snap.subscribe();
            let mut lv = d.level.subscribe();
            let json = serde_json::to_string(&*rx.borrow_and_update())?;
            write.write_all(format!("{json}\n").as_bytes()).await?;
            loop {
                tokio::select! {
                    r = rx.changed() => {
                        r?;
                        let json = serde_json::to_string(&*rx.borrow_and_update())?;
                        write.write_all(format!("{json}\n").as_bytes()).await?;
                    }
                    r = lv.changed() => {
                        r?;
                        let v = *lv.borrow_and_update();
                        write.write_all(format!("L {v:.3}\n").as_bytes()).await?;
                    }
                }
            }
        }
        "status" => {
            let json = serde_json::to_string(&*d.snap.borrow())?;
            write.write_all(format!("{json}\n").as_bytes()).await?;
        }
        _ => {
            let reply = d.command(line);
            write.write_all(format!("{reply}\n").as_bytes()).await?;
        }
    }
    Ok(())
}

pub async fn serve() -> Result<()> {
    let path = crate::socket_path();
    // Never steal the socket from a daemon that is still alive.
    if UnixStream::connect(&path).await.is_ok() {
        anyhow::bail!("another dictate daemon is already running on {}", path.display());
    }
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).with_context(|| format!("could not listen on {}", path.display()))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    let our_inode = std::fs::metadata(&path).map(|m| std::os::unix::fs::MetadataExt::ino(&m)).ok();

    let config = Config::load();
    let snapshot = Snapshot {
        daemon: true,
        state: "idle".into(),
        mode: "direct".into(),
        configured: crate::api_key().is_ok(),
        ..Default::default()
    };
    let dir = files::dir();
    eprintln!("dictate: takes go to {}", dir.display());
    let d = Arc::new(Daemon {
        snap: watch::channel(snapshot).0,
        level: watch::channel(0.0).0,
        ctl: Mutex::new(Ctl::default()),
        commands: Mutex::new(()),
        config: Mutex::new(config),
        http: reqwest::Client::builder().user_agent(concat!("dictate/", env!("CARGO_PKG_VERSION"))).build()?,
        dir,
    });

    eprintln!("dictate: listening on {}", path.display());
    let mut term = signal(SignalKind::terminate())?;
    let mut int = signal(SignalKind::interrupt())?;
    loop {
        tokio::select! {
            conn = listener.accept() => {
                if let Ok((stream, _)) = conn {
                    tokio::spawn(handle(d.clone(), stream));
                }
            }
            _ = term.recv() => break,
            _ = int.recv() => break,
        }
    }
    // Only remove the socket if it is still ours (a newer daemon may have replaced it).
    if std::fs::metadata(&path).map(|m| std::os::unix::fs::MetadataExt::ino(&m)).ok() == our_inode {
        let _ = std::fs::remove_file(&path);
    }
    Ok(())
}
