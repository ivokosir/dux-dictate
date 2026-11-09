mod audio;
mod daemon;
mod eleven;
mod files;
mod output;

use std::{
    env,
    io::{BufRead, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::PathBuf,
};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
};

const HELP: &str = "\
dictate - talk, and the text is pasted where you type

USAGE:
  dictate serve                 run the daemon (systemd does this)
  dictate toggle [direct|luna]  start, or stop and paste
  dictate start [direct|luna]   start recording
  dictate stop [direct|luna] [copy]
                                stop and paste (luna = clean up first, copy = clipboard only)
  dictate cancel                throw the recording away / dismiss a problem
  dictate retry                 transcribe the last failed take again
  dictate streaming on|off|toggle
  dictate status                print the state once (JSON)
  dictate watch                 print the state on every change (JSON lines)
  dictate set-key               save the ElevenLabs API key (read from stdin)

TAKES (plain files in ~/Music/Dictations, no daemon needed):
  dictate list [n]              newest takes as JSON
  dictate transcribe <take>     (re)make <take>.txt from <take>.ogg
  dictate clean <take>          make <take>.clean.txt with Luna
  dictate copy <take> [raw|clean]
  dictate reveal <take>         show it in the file manager
  dictate trash <take>|all      move to the trash
  dictate folder                open the folder
";

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct Config {
    /// Live transcription over a WebSocket instead of one upload at the end.
    pub streaming: bool,
    /// ISO language code, or "auto".
    pub language: String,
    /// Command that cleans the transcript in "luna" mode (stdin -> stdout).
    pub luna_command: String,
    pub luna_timeout_secs: u64,
    /// How many takes to keep in the folder (older ones go to the trash).
    pub keep: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            streaming: false,
            language: "en".into(),
            luna_command: home().join(".local/bin/voxtype-luna-cleanup").display().to_string(),
            luna_timeout_secs: 95,
            keep: 20,
        }
    }
}

impl Config {
    pub fn load() -> Self {
        std::fs::read_to_string(config_dir().join("config.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> Result<()> {
        let dir = config_dir();
        std::fs::create_dir_all(&dir)?;
        let tmp = dir.join("config.json.tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(self)? + "\n")?;
        std::fs::rename(tmp, dir.join("config.json"))?;
        Ok(())
    }
}

pub fn home() -> PathBuf {
    PathBuf::from(env::var("HOME").unwrap_or_else(|_| "/tmp".into()))
}

pub fn config_dir() -> PathBuf {
    env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home().join(".config"))
        .join("dictate")
}

pub fn state_dir() -> PathBuf {
    env::var("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home().join(".local/state"))
        .join("dictate")
}

pub fn socket_path() -> PathBuf {
    env::var("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
        .join("dictate.sock")
}

pub fn api_key() -> Result<String> {
    if let Ok(key) = env::var("ELEVENLABS_API_KEY") {
        if !key.trim().is_empty() {
            return Ok(key.trim().to_owned());
        }
    }
    let path = config_dir().join("api-key");
    let key = std::fs::read_to_string(&path)
        .with_context(|| format!("No ElevenLabs key. Run: dictate set-key ({})", path.display()))?;
    let key = key.trim().to_owned();
    if key.is_empty() {
        bail!("ElevenLabs key file is empty. Run: dictate set-key");
    }
    Ok(key)
}

fn set_key() -> Result<()> {
    if atty_stdin() {
        eprint!("ElevenLabs API key: ");
        std::io::stderr().flush().ok();
    }
    let mut key = String::new();
    std::io::stdin().lock().read_line(&mut key)?;
    let key = key.trim();
    if key.is_empty() {
        bail!("empty key");
    }
    let dir = config_dir();
    std::fs::create_dir_all(&dir)?;
    let path = dir.join("api-key");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    file.write_all(key.as_bytes())?;
    file.write_all(b"\n")?;
    eprintln!("saved {}", path.display());
    Ok(())
}

fn atty_stdin() -> bool {
    unsafe { libc::isatty(0) == 1 }
}

async fn client(line: String) -> Result<()> {
    let stream = match UnixStream::connect(socket_path()).await {
        Ok(stream) => stream,
        Err(error) => {
            if line == "watch" || line == "status" {
                println!("{{\"daemon\":false}}");
            }
            bail!("dictate daemon is not running ({error}). Start it: systemctl --user start dictate");
        }
    };
    let (read, mut write) = stream.into_split();
    write.write_all(format!("{line}\n").as_bytes()).await?;
    let mut lines = BufReader::new(read).lines();
    let mut out = std::io::stdout();
    while let Some(line) = lines.next_line().await? {
        writeln!(out, "{line}")?;
        out.flush()?;
    }
    Ok(())
}

/// Take commands work on the files directly, so they also work without the daemon.
async fn takes(args: &[String]) -> Result<()> {
    let dir = files::dir();
    let take = || -> Result<&str> { files::check_stamp(args.get(1).map(String::as_str).unwrap_or("")) };
    let changed = || async {
        // Let the bar know (if the daemon runs); harmless otherwise.
        if let Ok(mut s) = UnixStream::connect(socket_path()).await {
            let _ = s.write_all(b"refresh\n").await;
        }
    };
    match args[0].as_str() {
        "list" => {
            let n = args.get(1).and_then(|n| n.parse().ok()).unwrap_or(0);
            println!("{}", serde_json::to_string(&files::list(&dir, n))?);
        }
        "transcribe" => {
            let stamp = take()?;
            let config = Config::load();
            let data = std::fs::read(files::audio(&dir, stamp)).context("no audio for that take")?;
            let http = reqwest::Client::builder().user_agent(concat!("dictate/", env!("CARGO_PKG_VERSION"))).build()?;
            let text = eleven::transcribe(&http, &api_key()?, &config.language, data).await?;
            if text.trim().is_empty() {
                bail!("No speech heard");
            }
            files::write_text(&files::raw(&dir, stamp), &text)?;
            changed().await;
        }
        "clean" => {
            let stamp = take()?;
            let config = Config::load();
            let text = files::read_text(&files::raw(&dir, stamp)).context("not transcribed yet")?;
            let cleaned = output::luna(&config.luna_command, &text, config.luna_timeout_secs).await?;
            files::write_text(&files::clean(&dir, stamp), &cleaned)?;
            changed().await;
        }
        "copy" => {
            let stamp = take()?;
            let path = match args.get(2).map(String::as_str) {
                Some("clean") => files::clean(&dir, stamp),
                _ => files::raw(&dir, stamp),
            };
            let text = files::read_text(&path).context("that text does not exist")?;
            output::copy(&text).await?;
        }
        "reveal" => files::reveal(&files::audio(&dir, take()?)),
        "trash" => {
            if args.get(1).map(String::as_str) == Some("all") {
                for stamp in files::stamps(&dir) {
                    files::trash(&dir, &stamp)?;
                }
            } else {
                files::trash(&dir, take()?)?;
            }
            changed().await;
        }
        "folder" => {
            std::fs::create_dir_all(&dir)?;
            files::open(&dir);
        }
        _ => unreachable!(),
    }
    Ok(())
}

fn main() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("help");

    match cmd {
        "help" | "-h" | "--help" => {
            print!("{HELP}");
            return Ok(());
        }
        "set-key" => return set_key(),
        _ => {}
    }

    // The daemon gets worker threads; clients (watch/toggle) stay single-threaded and tiny.
    let runtime = if cmd == "serve" {
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build()?
    } else {
        tokio::runtime::Builder::new_current_thread().enable_all().build()?
    };

    let _ = rustls::crypto::ring::default_provider().install_default();
    match cmd {
        "serve" => runtime.block_on(daemon::serve()),
        "list" | "transcribe" | "clean" | "copy" | "reveal" | "trash" | "folder" => runtime.block_on(takes(&args)),
        "toggle" | "start" | "stop" | "cancel" | "retry" | "streaming" | "popout" | "refresh" | "status" | "watch" => {
            runtime.block_on(client(args.join(" ")))
        }
        other => {
            eprint!("unknown command: {other}\n\n{HELP}");
            std::process::exit(2);
        }
    }
}
