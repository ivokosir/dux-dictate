//! ElevenLabs Scribe: the whole recording goes up in one upload.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::Deserialize;

const API: &str = "https://api.elevenlabs.io";

/// Uploads a whole recording (here: the take's Ogg Opus file).
pub async fn transcribe(client: &reqwest::Client, key: &str, language: &str, audio: Vec<u8>) -> Result<String> {
    #[derive(Deserialize)]
    struct Reply {
        text: String,
    }

    let part = reqwest::multipart::Part::bytes(audio).file_name("audio.ogg").mime_str("audio/ogg")?;
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
        .timeout(Duration::from_secs(600))
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
