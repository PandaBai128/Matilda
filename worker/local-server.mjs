import { createHmac, randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { URL } from "node:url";

const TENCENT_ASR_HOST = "asr.cloud.tencent.com";

const env = loadEnvironment();
const port = Number(env.PORT || 8787);
const minimaxAPIHost = (env.MINIMAX_API_HOST || "https://api.minimax.io").replace(/\/+$/, "");
const MINIMAX_MESSAGES_URL = `${minimaxAPIHost}/anthropic/v1/messages`;
const MINIMAX_TTS_URL = `${minimaxAPIHost}/v1/t2a_v2`;
const MINIMAX_VOICES_URL = `${minimaxAPIHost}/v1/get_voice`;
const defaultMiniMaxTTSVolume = 2.5;

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);

    if (request.method !== "POST") {
      sendText(response, 405, "Method not allowed");
      return;
    }

    if (url.pathname === "/chat") {
      await handleChat(request, response);
      return;
    }

    if (url.pathname === "/tts") {
      await handleTTS(request, response);
      return;
    }

    if (url.pathname === "/voices") {
      await handleVoices(response);
      return;
    }

    if (url.pathname === "/transcribe-url") {
      await handleTranscribeURL(request, response);
      return;
    }

    sendText(response, 404, "Not found");
  } catch (error) {
    console.error("[local proxy] Unhandled error:", error);
    sendJSON(response, 500, { error: String(error) });
  }
});

server.listen(port, () => {
  console.log(`Clicky local proxy listening on http://localhost:${port}`);
});

async function handleChat(request, response) {
  requireEnv(["MINIMAX_API_KEY"]);

  const body = await readJSON(request);
  applyMiniMaxChatDefaults(body, env);

  const upstreamResponse = await fetch(MINIMAX_MESSAGES_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.MINIMAX_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  response.writeHead(upstreamResponse.status, {
    "content-type": upstreamResponse.headers.get("content-type") || "text/event-stream",
    "cache-control": "no-cache",
  });

  if (!upstreamResponse.body) {
    response.end();
    return;
  }

  for await (const chunk of upstreamResponse.body) {
    response.write(chunk);
  }
  response.end();
}

function applyMiniMaxChatDefaults(body, env) {
  body.model = env.MINIMAX_CHAT_MODEL || "MiniMax-M3";

  const thinkingType = String(env.MINIMAX_THINKING_TYPE || "disabled").trim().toLowerCase();
  if (thinkingType === "omit") {
    delete body.thinking;
  } else if (thinkingType === "disabled" || thinkingType === "adaptive") {
    body.thinking = { type: thinkingType };
  } else {
    body.thinking = { type: "adaptive" };
  }
}

async function handleTTS(request, response) {
  requireEnv(["MINIMAX_API_KEY"]);

  const incomingBody = await readJSON(request);
  const text = incomingBody.text?.trim();

  if (!text) {
    sendJSON(response, 400, { error: "Missing text for TTS." });
    return;
  }

  const upstreamResponse = await fetch(MINIMAX_TTS_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.MINIMAX_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: env.MINIMAX_TTS_MODEL || "speech-2.8-turbo",
      text,
      stream: false,
      language_boost: "auto",
      output_format: "hex",
      voice_setting: {
        voice_id: incomingBody.voice_id?.trim() || env.MINIMAX_TTS_VOICE_ID || "Chinese (Mandarin)_Warm_Bestie",
        speed: parseMiniMaxTTSSpeed(incomingBody.speed),
        vol: parseMiniMaxTTSVolume(incomingBody.volume ?? env.MINIMAX_TTS_VOLUME),
        pitch: parseMiniMaxTTSPitch(incomingBody.pitch),
        ...(incomingBody.emotion ? { emotion: incomingBody.emotion } : {}),
      },
      audio_setting: {
        sample_rate: 32000,
        bitrate: 128000,
        format: "mp3",
        channel: 1,
      },
    }),
  });

  const responseText = await upstreamResponse.text();

  if (!upstreamResponse.ok) {
    console.error("[local proxy] MiniMax TTS error:", responseText);
    sendText(response, upstreamResponse.status, responseText, "application/json");
    return;
  }

  const payload = JSON.parse(responseText);
  if (payload.base_resp?.status_code && payload.base_resp.status_code !== 0) {
    sendJSON(response, 502, {
      error: payload.base_resp.status_msg || "MiniMax TTS returned an error.",
      base_resp: payload.base_resp,
    });
    return;
  }

  if (!payload.data?.audio) {
    sendJSON(response, 502, { error: "MiniMax TTS returned no audio." });
    return;
  }

  const audioBuffer = Buffer.from(payload.data.audio.trim(), "hex");
  response.writeHead(200, { "content-type": "audio/mpeg" });
  response.end(audioBuffer);
}

async function handleVoices(response) {
  requireEnv(["MINIMAX_API_KEY"]);

  const upstreamResponse = await fetch(MINIMAX_VOICES_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.MINIMAX_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ voice_type: "all" }),
  });

  const responseText = await upstreamResponse.text();
  if (!upstreamResponse.ok) {
    console.error("[local proxy] MiniMax voice catalog error:", responseText);
  }
  sendText(response, upstreamResponse.status, responseText, "application/json");
}

async function handleTranscribeURL(request, response) {
  requireEnv([
    "TENCENT_ASR_APP_ID",
    "TENCENT_ASR_SECRET_ID",
    "TENCENT_ASR_SECRET_KEY",
  ]);

  const body = await readJSON(request).catch(() => ({}));
  const voiceId = randomUUID();
  const timestamp = Math.floor(Date.now() / 1000);
  const expired = timestamp + 600;
  const nonce = Math.floor(Math.random() * 1_000_000_000).toString();

  const params = {
    secretid: env.TENCENT_ASR_SECRET_ID,
    timestamp: String(timestamp),
    expired: String(expired),
    nonce,
    engine_model_type: env.TENCENT_ASR_ENGINE_MODEL_TYPE || "16k_zh_en",
    voice_id: voiceId,
    voice_format: "1",
    needvad: "1",
    filter_empty_result: "1",
    convert_num_mode: "1",
    vad_silence_time: "1000",
  };

  if (env.TENCENT_ASR_ENABLE_HOTWORDS === "1") {
    const hotwordList = makeHotwordList(body.keyterms || []);
    if (hotwordList) {
      params.hotword_list = hotwordList;
    }
  }

  const signedPath = `/asr/v2/${env.TENCENT_ASR_APP_ID}`;
  const signatureSource = `${TENCENT_ASR_HOST}${signedPath}?${makeSortedQueryString(params)}`;
  const signature = createHmac("sha1", env.TENCENT_ASR_SECRET_KEY)
    .update(signatureSource)
    .digest("base64");

  const finalQuery = new URLSearchParams(params);
  finalQuery.set("signature", signature);

  sendJSON(response, 200, {
    websocket_url: `wss://${TENCENT_ASR_HOST}${signedPath}?${finalQuery.toString()}`,
    voice_id: voiceId,
    expires_at: expired,
  });
}

function loadEnvironment() {
  const loadedEnv = { ...process.env };

  for (const filename of [".dev.vars", ".env"]) {
    if (!existsSync(filename)) {
      continue;
    }

    const fileContents = readFileSync(filename, "utf8");
    for (const line of fileContents.split(/\r?\n/)) {
      const trimmedLine = line.trim();
      if (!trimmedLine || trimmedLine.startsWith("#")) {
        continue;
      }

      const separatorIndex = trimmedLine.indexOf("=");
      if (separatorIndex === -1) {
        continue;
      }

      const key = trimmedLine.slice(0, separatorIndex).trim();
      const rawValue = trimmedLine.slice(separatorIndex + 1).trim();
      loadedEnv[key] = rawValue.replace(/^["']|["']$/g, "");
    }
  }

  return loadedEnv;
}

function requireEnv(requiredKeys) {
  const missingKeys = requiredKeys.filter((key) => !env[key]);
  if (missingKeys.length > 0) {
    throw new Error(`Missing environment variables: ${missingKeys.join(", ")}`);
  }
}

function parseMiniMaxTTSVolume(rawVolume) {
  const parsedVolume = Number(rawVolume || defaultMiniMaxTTSVolume);
  if (!Number.isFinite(parsedVolume)) {
    return defaultMiniMaxTTSVolume;
  }

  return Math.max(0.1, Math.min(parsedVolume, 10));
}

function parseMiniMaxTTSSpeed(rawSpeed) {
  const parsedSpeed = Number(rawSpeed ?? 1);
  return Number.isFinite(parsedSpeed) ? Math.max(0.5, Math.min(parsedSpeed, 2)) : 1;
}

function parseMiniMaxTTSPitch(rawPitch) {
  const parsedPitch = Number(rawPitch ?? 0);
  return Number.isFinite(parsedPitch) ? Math.round(Math.max(-12, Math.min(parsedPitch, 12))) : 0;
}

async function readJSON(request) {
  const chunks = [];
  for await (const chunk of request) {
    chunks.push(chunk);
  }

  const body = Buffer.concat(chunks).toString("utf8");
  return body ? JSON.parse(body) : {};
}

function makeHotwordList(keyterms) {
  const normalizedKeyterms = keyterms
    .map((term) => String(term).trim())
    .filter(Boolean)
    .slice(0, 128)
    .map((term) => `${term.replace(/[,\s|]/g, "")}|8`)
    .filter((term) => term.length > 2);

  return normalizedKeyterms.length > 0 ? normalizedKeyterms.join(",") : null;
}

function makeSortedQueryString(params) {
  return Object.keys(params)
    .sort()
    .map((key) => `${key}=${params[key]}`)
    .join("&");
}

function sendJSON(response, statusCode, payload) {
  sendText(response, statusCode, JSON.stringify(payload), "application/json");
}

function sendText(response, statusCode, text, contentType = "text/plain") {
  response.writeHead(statusCode, { "content-type": contentType });
  response.end(text);
}
