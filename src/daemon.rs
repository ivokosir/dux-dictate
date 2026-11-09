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
    sync::{mpsc, oneshot, watch},
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
    /// When state is "problem": cleanfail | paste | nospeech | mic | eleven | nokey | other
    problem: String,
    /// Details for a problem (shown as a tooltip).
    message: String,
    /// direct | luna
    mode: String,
    /// Setting: the next recording streams live.
    streaming: bool,
    /// The current recording streams live.
    live: bool,
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

/// What live typing got done.
#[derive(Default)]
struct Typed {
    /// Something was typed into the app.
    any: bool,
    /// Pieces still held back (the popout was open).
    backlog: Vec<String>,
}

#[derive(Clone, Copy, PartialEq)]
enum Delivered {
    /// The text is already in the app (typed live).
    Typed,
    Not,
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
            "cleancopied" => Some(5),
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
            "retry" if !busy && state != "recording" => self.retry(),
            "streaming" if state != "recording" && !busy => {
                let mut config = self.config.lock().unwrap();
                config.streaming = match args.first().copied() {
                    Some("on") => true,
                    Some("off") => false,
                    _ => !config.streaming,
                };
                if let Err(error) = config.save() {
                    eprintln!("dictate: could not save config: {error}");
                }
                let on = config.streaming;
                self.update(|s| s.streaming = on);
            }
            "popout" => {
                let open = args.first().copied() == Some("on");
                self.update(|s| s.popout = open);
            }
            "refresh" => self.files_changed(),
            "start" | "stop" | "retry" | "streaming" => {}
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
        let live = config.streaming;
        let stamp = files::new_stamp(&self.dir);
        self.update(|s| {
            s.state = "recording".into();
            s.problem.clear();
            s.message.clear();
            s.mode = mode.name().into();
            s.live = live;
            s.started_ms = now_ms();
            s.can_retry = false;
            s.configured = crate::api_key().is_ok();
            s.current = stamp.clone();
        });
        tokio::spawn(self.clone().run(id, stamp, mode, live, config, rx));
    }

    async fn run(
        self: Arc<Self>,
        id: u64,
        stamp: String,
        mode: Mode,
        live: bool,
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

        // Live mode: audio also goes to the WebSocket while we record.
        let (audio_tx, audio_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let mut audio_tx = live.then_some(audio_tx);
        // Live mode types each finished piece of text straight into the focused app.
        let mut typer_task = None;
        let mut stream_task = if live {
            let key = key.clone();
            let language = config.language.clone();
            let (seg_tx, seg_rx) = mpsc::unbounded_channel::<String>();
            typer_task = Some(tokio::spawn(self.clone().typer(seg_rx)));
            Some(tokio::spawn(async move {
                eleven::stream(&key, &language, audio_rx, move |seg| {
                    let _ = seg_tx.send(seg);
                })
                .await
            }))
        } else {
            drop(audio_rx);
            None
        };

        let mut bytes = 0usize;
        let mut pending: Vec<u8> = Vec::new();
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
                        if let Some(tx) = &audio_tx {
                            pending.extend_from_slice(data);
                            if pending.len() >= 3200 {
                                let _ = tx.send(std::mem::take(&mut pending));
                            }
                        }
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
        if let Some(tx) = audio_tx.take() {
            pending.extend_from_slice(&rest);
            if !pending.is_empty() {
                let _ = tx.send(pending);
            }
            // Dropping the sender tells the stream to commit and finish.
        }

        let remove_take = |d: &Daemon| {
            let _ = std::fs::remove_file(files::audio(&d.dir, &stamp));
        };
        let (final_mode, out) = match stop {
            Stop::Cancel => {
                if let Some(task) = stream_task.take() {
                    task.abort();
                }
                if let Some(task) = typer_task.take() {
                    task.abort();
                }
                let _ = encoder.finish().await;
                remove_take(&self);
                return self.idle(id);
            }
            Stop::Finish(m, out) => (m.unwrap_or(mode), out),
        };

        if bytes < BYTES_PER_SEC * 3 / 10 {
            if let Some(task) = stream_task.take() {
                task.abort();
            }
            if let Some(task) = typer_task.take() {
                task.abort();
            }
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

        let mut text = String::new();
        let mut typed = Typed::default();
        if let Some(task) = stream_task.take() {
            match tokio::time::timeout(Duration::from_secs(10), task).await {
                Ok(Ok(Ok(t))) => text = t,
                Ok(Ok(Err(e))) => eprintln!("dictate: live failed, uploading instead: {e:#}"),
                _ => eprintln!("dictate: live did not finish, uploading instead"),
            }
        }
        if let Some(task) = typer_task.take() {
            // The stream is done, so the typer gets no more pieces and finishes.
            typed = tokio::time::timeout(Duration::from_secs(10), task).await.ok().and_then(|r| r.ok()).unwrap_or_default();
        }
        // Live broke halfway: part is already typed, so don't paste on top of it.
        let live_broke = typed.any && text.trim().is_empty();
        if text.trim().is_empty() {
            let result = match std::fs::read(&ogg) {
                Ok(data) => eleven::transcribe(&self.http, &key, &config.language, data).await,
                Err(error) => Err(anyhow::anyhow!("the audio file is missing: {error}")),
            };
            match result {
                Ok(t) => text = t,
                Err(error) => {
                    let failed = saved.is_ok().then(|| Failed { stamp: stamp.clone(), mode: final_mode, out });
                    return self.problem(id, "eleven", format!("{error:#}"), failed);
                }
            }
        }
        if live_broke {
            let _ = files::write_text(&files::raw(&self.dir, &stamp), &text);
            let _ = output::copy(&text).await;
            self.files_changed();
            return self.problem(id, "livefail", "Live stopped halfway; the full text is on your clipboard".into(), None);
        }
        // Pieces typed live are done; whatever is left (popout was open) goes out now.
        let rest = if typed.any && out == Out::Paste {
            for piece in &typed.backlog {
                if let Err(error) = output::type_text(&format!(" {piece}")).await {
                    eprintln!("dictate: typing failed: {error:#}");
                }
            }
            Delivered::Typed
        } else {
            Delivered::Not
        };
        self.deliver(id, stamp, text, final_mode, out, rest, &config).await;
    }

    /// Types live pieces as they arrive, but holds them while the popout is open
    /// (it has the keyboard). Returns what is still held at the end.
    async fn typer(self: Arc<Self>, mut rx: mpsc::UnboundedReceiver<String>) -> Typed {
        let mut typed = Typed::default();
        let mut held: std::collections::VecDeque<String> = Default::default();
        loop {
            tokio::select! {
                piece = rx.recv() => match piece {
                    Some(p) => held.push_back(p),
                    None => break,
                },
                _ = tokio::time::sleep(Duration::from_millis(200)), if !held.is_empty() => {}
            }
            while !self.snap.borrow().popout {
                let Some(piece) = held.pop_front() else { break };
                let text = if typed.any { format!(" {piece}") } else { piece };
                match output::type_text(&text).await {
                    Ok(()) => typed.any = true,
                    Err(error) => eprintln!("dictate: typing failed: {error:#}"),
                }
            }
        }
        typed.backlog = held.into();
        typed
    }

    async fn deliver(
        self: &Arc<Self>,
        id: u64,
        stamp: String,
        text: String,
        mode: Mode,
        out: Out,
        done: Delivered,
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
        // Live already typed the raw text: a cleaned version can only go to the clipboard.
        let cleaned_after_typing = done == Delivered::Typed && mode == Mode::Luna && clean_failed.is_none();
        let delivered = match (out, done) {
            (Out::Copy, _) => output::copy(&text).await,
            (Out::Paste, Delivered::Typed) if cleaned_after_typing => output::copy(&text).await,
            (Out::Paste, Delivered::Typed) => Ok(()),
            (Out::Paste, Delivered::Not) => output::paste(&text).await,
        };
        files::prune(&self.dir, config.keep, &stamp);
        self.files_changed();
        if let Err(error) = delivered {
            return self.problem(id, "paste", error.to_string(), None);
        }
        if let Some(message) = clean_failed {
            return self.problem(id, "cleanfail", message, None);
        }
        if cleaned_after_typing {
            return self.problem(id, "cleancopied", String::new(), None);
        }
        self.idle(id);
    }

    fn retry(self: &Arc<Self>) {
        let Some(Failed { stamp, mode, out }) = self.ctl.lock().unwrap().failed.take() else { return };
        let id = self.new_session();
        let config = self.config.lock().unwrap().clone();
        self.update(|s| {
            s.state = "transcribing".into();
            s.problem.clear();
            s.message.clear();
            s.mode = mode.name().into();
            s.live = false;
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
                Ok(text) => d.deliver(id, stamp, text, mode, out, Delivered::Not, &config).await,
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
        streaming: config.streaming,
        configured: crate::api_key().is_ok(),
        ..Default::default()
    };
    let dir = files::dir();
    eprintln!("dictate: takes go to {}", dir.display());
    let d = Arc::new(Daemon {
        snap: watch::channel(snapshot).0,
        level: watch::channel(0.0).0,
        ctl: Mutex::new(Ctl::default()),
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
