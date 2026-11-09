//! ElevenLabs Scribe: one upload (batch) or a live WebSocket (streaming).

use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::{sync::mpsc, time::Instant};
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest, http::HeaderValue};

const API: &str = "https://api.elevenlabs.io";
const WS: &str = "wss://api.elevenlabs.io/v1/speech-to-text/realtime";

pub async fn transcribe(client: &reqwest::Client, key: &str, language: &str, wav: Vec<u8>) -> Result<String> {
    #[derive(Deserialize)]
    struct Reply {
        text: String,
    }

    let part = reqwest::multipart::Part::bytes(wav).file_name("audio.wav").mime_str("audio/wav")?;
    let mut form = reqwest::multipart::Form::new()
        .part("file", part)
        .text("model_id", "scribe_v2")
        .text("tag_audio_events", "false")
        .text("diarize", "false")
        .text("timestamps_granularity", "none");
    if !language.is_empty() && language != "auto" {
        form = form.text("language_code", language.to_owned());
    }

    let response = client
        .post(format!("{API}/v1/speech-to-text"))
        .header("xi-api-key", key)
        .multipart(form)
        .timeout(Duration::from_secs(120))
        .send()
        .await
        .context("could not reach ElevenLabs")?;
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    if !status.is_success() {
        bail!("ElevenLabs said {status}: {}", short_error(&body));
    }
    let reply: Reply = serde_json::from_str(&body).context("unexpected reply from ElevenLabs")?;
    Ok(reply.text.trim().to_owned())
}

fn short_error(body: &str) -> String {
    let parsed: Option<serde_json::Value> = serde_json::from_str(body).ok();
    let msg = parsed
        .as_ref()
        .and_then(|v| v.pointer("/detail/message").or_else(|| v.get("detail")))
        .map(|v| v.as_str().map(str::to_owned).unwrap_or_else(|| v.to_string()))
        .unwrap_or_else(|| body.to_owned());
    msg.chars().take(200).collect()
}

/// Streams audio from `audio` until the channel closes, then commits and
/// returns the full transcript. `on_text` gets the live text as it grows.
pub async fn stream(
    key: &str,
    language: &str,
    mut audio: mpsc::UnboundedReceiver<Vec<u8>>,
    on_text: impl Fn(String),
) -> Result<String> {
    let mut url = format!("{WS}?model_id=scribe_v2_realtime&audio_format=pcm_16000&commit_strategy=vad");
    if !language.is_empty() && language != "auto" {
        url.push_str(&format!("&language_code={language}"));
    }
    let mut request = url.into_client_request()?;
    request.headers_mut().insert("xi-api-key", HeaderValue::from_str(key)?);

    let (ws, _) = tokio::time::timeout(Duration::from_secs(8), tokio_tungstenite::connect_async(request))
        .await
        .map_err(|_| anyhow!("live connection timed out"))?
        .context("could not open live connection")?;
    let (mut tx, mut rx) = ws.split();

    let b64 = base64::engine::general_purpose::STANDARD;
    let chunk = |pcm: &[u8], commit: bool| {
        Message::text(
            serde_json::json!({
                "message_type": "input_audio_chunk",
                "audio_base_64": b64.encode(pcm),
                "commit": commit,
                "sample_rate": 16000,
            })
            .to_string(),
        )
    };

    let mut committed: Vec<String> = Vec::new();
    let mut partial = String::new();
    let mut closing = false;
    let mut commit_after_close = false;
    let mut hard_deadline = Instant::now() + Duration::from_secs(3600);
    let mut quiet_deadline = hard_deadline;

    let joined = |committed: &[String], partial: &str| {
        let mut parts: Vec<&str> = committed.iter().map(String::as_str).collect();
        if !partial.trim().is_empty() {
            parts.push(partial.trim());
        }
        parts.join(" ")
    };

    loop {
        tokio::select! {
            pcm = audio.recv(), if !closing => match pcm {
                Some(pcm) => tx.send(chunk(&pcm, false)).await.context("live connection dropped")?,
                None => {
                    // 100 ms of silence carries the final commit.
                    tx.send(chunk(&[0u8; 3200], true)).await.context("live connection dropped")?;
                    closing = true;
                    let now = Instant::now();
                    hard_deadline = now + Duration::from_secs(6);
                    quiet_deadline = now + Duration::from_millis(1500);
                }
            },
            msg = rx.next() => {
                let Some(msg) = msg else {
                    if closing { break } else { bail!("live connection closed") }
                };
                let msg = msg.context("live connection error")?;
                let Message::Text(text) = msg else { continue };
                let v: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
                let kind = v["message_type"].as_str().unwrap_or("");
                match kind {
                    "partial_transcript" => {
                        partial = v["text"].as_str().unwrap_or("").to_owned();
                        on_text(joined(&committed, &partial));
                    }
                    "committed_transcript" => {
                        let t = v["text"].as_str().unwrap_or("").trim().to_owned();
                        if !t.is_empty() {
                            committed.push(t);
                        }
                        partial.clear();
                        on_text(joined(&committed, &partial));
                        if closing {
                            commit_after_close = true;
                        }
                    }
                    "session_started" | "warning" => {}
                    _ if v.get("error").is_some() => {
                        if closing {
                            break; // e.g. nothing left to commit: keep what we have
                        }
                        bail!("live: {}", v["error"].as_str().unwrap_or(kind));
                    }
                    _ => {}
                }
                if closing {
                    if commit_after_close && partial.trim().is_empty() {
                        // Give a moment for one more segment, then finish.
                        quiet_deadline = Instant::now() + Duration::from_millis(250);
                    } else {
                        quiet_deadline = Instant::now() + Duration::from_millis(1500);
                    }
                }
            },
            _ = tokio::time::sleep_until(quiet_deadline.min(hard_deadline)), if closing => break,
        }
    }

    let _ = tx.send(Message::Close(None)).await;
    Ok(joined(&committed, &partial))
}
