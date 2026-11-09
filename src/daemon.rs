//! The background service: one recording at a time, state broadcast to the UI.

use std::{
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
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
    audio::{self, BYTES_PER_SEC, Recorder},
    eleven, output,
};

const HISTORY: usize = 15;

#[derive(Serialize, Clone, Default)]
pub struct Snapshot {
    daemon: bool,
    /// idle | recording | transcribing | cleaning | done | error
    state: String,
    /// direct | luna
    mode: String,
    /// Setting: the next recording streams live.
    streaming: bool,
    /// The current recording streams live.
    live: bool,
    started_ms: u64,
    level: f32,
    text: String,
    error: String,
    can_retry: bool,
    configured: bool,
    history: Vec<Entry>,
}

#[derive(Serialize, Clone)]
struct Entry {
    text: String,
    at_ms: u64,
    mode: String,
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

enum Stop {
    Finish(Option<Mode>),
    Cancel,
}

#[derive(Default)]
struct Ctl {
    session: u64,
    stop: Option<oneshot::Sender<Stop>>,
    failed: Option<(PathBuf, Mode)>,
}

struct Daemon {
    snap: watch::Sender<Snapshot>,
    ctl: Mutex<Ctl>,
    config: Mutex<Config>,
    http: reqwest::Client,
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

    /// Hide the card after a moment, unless something new happened.
    fn settle_later(self: &Arc<Self>, id: u64, after: Duration) {
        let d = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(after).await;
            if d.is_current(id) && matches!(d.state().as_str(), "done" | "error") {
                d.update(|s| {
                    s.state = "idle".into();
                    s.text.clear();
                    s.error.clear();
                });
            }
        });
    }

    fn idle(&self, id: u64) {
        if self.is_current(id) {
            self.update(|s| {
                s.state = "idle".into();
                s.level = 0.0;
                s.text.clear();
                s.error.clear();
            });
        }
    }

    fn fail(self: &Arc<Self>, id: u64, message: String, saved: Option<(PathBuf, Mode)>) {
        eprintln!("dictate: {message}");
        if !self.is_current(id) {
            return;
        }
        let can_retry = saved.is_some();
        self.ctl.lock().unwrap().failed = saved;
        self.update(|s| {
            s.state = "error".into();
            s.level = 0.0;
            s.error = message;
            s.can_retry = can_retry;
        });
        self.settle_later(id, Duration::from_secs(10));
    }

    fn command(self: &Arc<Self>, line: &str) -> String {
        let mut words = line.split_whitespace();
        let cmd = words.next().unwrap_or("");
        let arg = words.next();
        let state = self.state();
        let busy = matches!(state.as_str(), "transcribing" | "cleaning");
        match cmd {
            "toggle" => match state.as_str() {
                "recording" => self.stop(Stop::Finish(Mode::parse(arg))),
                _ if busy => {}
                _ => self.start(Mode::parse(arg).unwrap_or(Mode::Direct)),
            },
            "start" if state != "recording" && !busy => self.start(Mode::parse(arg).unwrap_or(Mode::Direct)),
            "stop" if state == "recording" => self.stop(Stop::Finish(Mode::parse(arg))),
            "cancel" => {
                if state == "recording" {
                    self.stop(Stop::Cancel);
                } else {
                    let id = self.new_session();
                    self.idle(id);
                }
            }
            "retry" if state != "recording" && !busy => self.retry(),
            "streaming" => {
                let mut config = self.config.lock().unwrap();
                config.streaming = match arg {
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
            ctl.session
        };
        let config = self.config.lock().unwrap().clone();
        let live = config.streaming;
        self.update(|s| {
            s.state = "recording".into();
            s.mode = mode.name().into();
            s.live = live;
            s.started_ms = now_ms();
            s.level = 0.0;
            s.text.clear();
            s.error.clear();
            s.can_retry = false;
            s.configured = crate::api_key().is_ok();
        });
        tokio::spawn(self.clone().run(id, mode, live, config, rx));
    }

    async fn run(self: Arc<Self>, id: u64, mode: Mode, live: bool, config: Config, mut stop_rx: oneshot::Receiver<Stop>) {
        let key = match crate::api_key() {
            Ok(key) => key,
            Err(error) => return self.fail(id, error.to_string(), None),
        };
        let mut recorder = match Recorder::start() {
            Ok(r) => r,
            Err(error) => return self.fail(id, error.to_string(), None),
        };

        // Live mode: audio goes to the WebSocket while we record.
        let (audio_tx, audio_rx) = mpsc::unbounded_channel::<Vec<u8>>();
        let mut audio_tx = live.then_some(audio_tx);
        let mut stream_task = if live {
            let d = self.clone();
            let key = key.clone();
            let language = config.language.clone();
            Some(tokio::spawn(async move {
                eleven::stream(&key, &language, audio_rx, move |text| {
                    if d.is_current(id) {
                        d.update(|s| s.text = text);
                    }
                })
                .await
            }))
        } else {
            drop(audio_rx);
            None
        };

        let mut pcm: Vec<u8> = Vec::with_capacity(BYTES_PER_SEC * 60);
        let mut pending: Vec<u8> = Vec::new();
        let mut buf = vec![0u8; 4096];
        let mut window: Vec<u8> = Vec::new();
        let mut last_level = Instant::now();
        let limit = tokio::time::sleep(Duration::from_secs(config.max_minutes.max(1) * 60));
        tokio::pin!(limit);
        let mut mic_lost = false;

        let stop = loop {
            tokio::select! {
                how = &mut stop_rx => break how.unwrap_or(Stop::Cancel),
                _ = &mut limit => break Stop::Finish(None),
                n = recorder.read(&mut buf) => match n {
                    Ok(n) if n > 0 => {
                        let data = &buf[..n];
                        pcm.extend_from_slice(data);
                        window.extend_from_slice(data);
                        if let Some(tx) = &audio_tx {
                            pending.extend_from_slice(data);
                            if pending.len() >= 3200 {
                                let _ = tx.send(std::mem::take(&mut pending));
                            }
                        }
                        if last_level.elapsed() >= Duration::from_millis(45) {
                            let level = audio::level(&window);
                            window.clear();
                            last_level = Instant::now();
                            self.update(|s| s.level = level);
                        }
                    }
                    _ => {
                        mic_lost = true;
                        break Stop::Finish(None);
                    }
                }
            }
        };

        let rest = recorder.finish().await;
        pcm.extend_from_slice(&rest);
        if let Some(tx) = audio_tx.take() {
            pending.extend_from_slice(&rest);
            if !pending.is_empty() {
                let _ = tx.send(pending);
            }
            // Dropping the sender tells the stream to commit and finish.
        }

        let final_mode = match stop {
            Stop::Cancel => {
                if let Some(task) = stream_task.take() {
                    task.abort();
                }
                return self.idle(id);
            }
            Stop::Finish(m) => m.unwrap_or(mode),
        };

        if pcm.len() < BYTES_PER_SEC * 3 / 10 {
            if let Some(task) = stream_task.take() {
                task.abort();
            }
            if mic_lost {
                return self.fail(id, "Could not record from the microphone".into(), None);
            }
            return self.idle(id);
        }

        self.update(|s| {
            s.state = "transcribing".into();
            s.mode = final_mode.name().into();
            s.level = 0.0;
        });

        // Keep the audio on disk until it is transcribed, so nothing is lost.
        let wav = audio::wav(&pcm);
        let saved = save_recording(&wav).map_err(|e| eprintln!("dictate: could not back up audio: {e}")).ok();

        let mut text = String::new();
        if let Some(task) = stream_task.take() {
            match tokio::time::timeout(Duration::from_secs(10), task).await {
                Ok(Ok(Ok(t))) => text = t,
                Ok(Ok(Err(e))) => eprintln!("dictate: live failed, uploading instead: {e:#}"),
                _ => eprintln!("dictate: live did not finish, uploading instead"),
            }
        }
        if text.trim().is_empty() {
            match eleven::transcribe(&self.http, &key, &config.language, wav).await {
                Ok(t) => text = t,
                Err(error) => {
                    let message = format!("{error:#}");
                    return self.fail(id, message, saved.map(|p| (p, final_mode)));
                }
            }
        }
        if let Some(path) = &saved {
            let _ = std::fs::remove_file(path);
        }
        self.deliver(id, text, final_mode, &config).await;
    }

    async fn deliver(self: &Arc<Self>, id: u64, text: String, mode: Mode, config: &Config) {
        if !self.is_current(id) {
            return;
        }
        let mut text = text.trim().to_owned();
        if text.is_empty() {
            return self.fail(id, "No speech heard".into(), None);
        }
        if mode == Mode::Luna {
            self.update(|s| {
                s.state = "cleaning".into();
                s.text = text.clone();
            });
            match output::luna(&config.luna_command, &text, config.luna_timeout_secs).await {
                Ok(cleaned) => text = cleaned,
                Err(error) => eprintln!("dictate: cleanup failed, pasting the original: {error:#}"),
            }
            if !self.is_current(id) {
                return;
            }
        }
        let pasted = output::paste(&text).await;
        let entry = Entry { text: text.clone(), at_ms: now_ms(), mode: mode.name().into() };
        self.update(|s| {
            s.state = "done".into();
            s.text = text;
            s.error = pasted.err().map(|e| e.to_string()).unwrap_or_default();
            s.history.insert(0, entry);
            s.history.truncate(HISTORY);
        });
        self.settle_later(id, Duration::from_millis(2600));
    }

    fn retry(self: &Arc<Self>) {
        let Some((path, mode)) = self.ctl.lock().unwrap().failed.take() else { return };
        let id = self.new_session();
        let config = self.config.lock().unwrap().clone();
        self.update(|s| {
            s.state = "transcribing".into();
            s.mode = mode.name().into();
            s.live = false;
            s.text.clear();
            s.error.clear();
            s.can_retry = false;
        });
        let d = self.clone();
        tokio::spawn(async move {
            let result = async {
                let key = crate::api_key()?;
                let wav = std::fs::read(&path).context("the saved recording is gone")?;
                eleven::transcribe(&d.http, &key, &config.language, wav).await
            }
            .await;
            match result {
                Ok(text) => {
                    let _ = std::fs::remove_file(&path);
                    d.deliver(id, text, mode, &config).await;
                }
                Err(error) => d.fail(id, format!("{error:#}"), Some((path, mode))),
            }
        });
    }
}

fn save_recording(wav: &[u8]) -> Result<PathBuf> {
    use std::io::Write;
    let dir = crate::state_dir().join("recordings");
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    let path = dir.join(format!("{}.wav", now_ms()));
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
    file.write_all(wav)?;
    Ok(path)
}

async fn handle(d: Arc<Daemon>, stream: UnixStream) -> Result<()> {
    let (read, mut write) = stream.into_split();
    let mut line = String::new();
    BufReader::new(read).read_line(&mut line).await?;
    let line = line.trim();
    match line {
        "watch" => {
            let mut rx = d.snap.subscribe();
            loop {
                let json = serde_json::to_string(&*rx.borrow_and_update())?;
                write.write_all(format!("{json}\n").as_bytes()).await?;
                rx.changed().await?;
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
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path).with_context(|| format!("could not listen on {}", path.display()))?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;

    let config = Config::load();
    let snapshot = Snapshot {
        daemon: true,
        state: "idle".into(),
        mode: "direct".into(),
        streaming: config.streaming,
        configured: crate::api_key().is_ok(),
        ..Default::default()
    };
    let d = Arc::new(Daemon {
        snap: watch::channel(snapshot).0,
        ctl: Mutex::new(Ctl::default()),
        config: Mutex::new(config),
        http: reqwest::Client::builder().user_agent(concat!("dictate/", env!("CARGO_PKG_VERSION"))).build()?,
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
    let _ = std::fs::remove_file(&path);
    Ok(())
}
