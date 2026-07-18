/**
 * Clicky Proxy Worker
 *
 * Proxies requests to MiniMax and signs Tencent Cloud ASR websocket URLs so
 * the macOS app never ships with raw API keys.
 *
 * Routes:
 *   POST /chat           -> MiniMax Anthropic-compatible Messages API
 *   POST /tts            -> MiniMax T2A HTTP API, returned as audio/mpeg
 *   POST /voices         -> MiniMax voice catalog for the configured account
 *   POST /transcribe-url -> Tencent Cloud realtime ASR signed websocket URL
 */

interface Env {
  MINIMAX_API_KEY: string;
  MINIMAX_API_HOST?: string;
  MINIMAX_CHAT_MODEL?: string;
  MINIMAX_THINKING_TYPE?: string;
  MINIMAX_TTS_VOICE_ID?: string;
  MINIMAX_TTS_MODEL?: string;
  MINIMAX_TTS_VOLUME?: string;
  TENCENT_ASR_APP_ID: string;
  TENCENT_ASR_SECRET_ID: string;
  TENCENT_ASR_SECRET_KEY: string;
  TENCENT_ASR_ENGINE_MODEL_TYPE?: string;
  TENCENT_ASR_ENABLE_HOTWORDS?: string;
}

const TENCENT_ASR_HOST = "asr.cloud.tencent.com";
const defaultMiniMaxTTSVolume = 2.5;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const minimaxAPIHost = (env.MINIMAX_API_HOST || "https://api.minimax.io").replace(/\/+$/, "");
    const minimaxMessagesURL = `${minimaxAPIHost}/anthropic/v1/messages`;
    const minimaxTTSURL = `${minimaxAPIHost}/v1/t2a_v2`;
    const minimaxVoicesURL = `${minimaxAPIHost}/v1/get_voice`;

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env, minimaxMessagesURL);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env, minimaxTTSURL);
      }

      if (url.pathname === "/voices") {
        return await handleVoices(env, minimaxVoicesURL);
      }

      if (url.pathname === "/transcribe-url") {
        return await handleTranscribeURL(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonResponse({ error: String(error) }, 500);
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env, minimaxMessagesURL: string): Promise<Response> {
  const body = await request.json<Record<string, unknown>>();

  applyMiniMaxChatDefaults(body, env);

  const response = await fetch(minimaxMessagesURL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.MINIMAX_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] MiniMax API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

function applyMiniMaxChatDefaults(body: Record<string, unknown>, env: Env): void {
  body.model = env.MINIMAX_CHAT_MODEL || "MiniMax-M3";

  const thinkingType = (env.MINIMAX_THINKING_TYPE || "disabled").trim().toLowerCase();
  if (thinkingType === "omit") {
    delete body.thinking;
  } else if (thinkingType === "disabled" || thinkingType === "adaptive") {
    body.thinking = { type: thinkingType };
  } else {
    body.thinking = { type: "adaptive" };
  }
}

async function handleTTS(request: Request, env: Env, minimaxTTSURL: string): Promise<Response> {
  const incomingBody = await request.json<{
    text?: string;
    voice_id?: string;
    volume?: number;
    speed?: number;
    pitch?: number;
    emotion?: string;
  }>();
  const text = incomingBody.text?.trim();
  const requestedVoiceId = incomingBody.voice_id?.trim();

  if (!text) {
    return jsonResponse({ error: "Missing text for TTS." }, 400);
  }

  const response = await fetch(minimaxTTSURL, {
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
        voice_id: requestedVoiceId || env.MINIMAX_TTS_VOICE_ID || "Chinese (Mandarin)_Warm_Bestie",
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

  const responseText = await response.text();

  if (!response.ok) {
    console.error(`[/tts] MiniMax TTS error ${response.status}: ${responseText}`);
    return new Response(responseText, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const payload = JSON.parse(responseText) as {
    data?: { audio?: string };
    base_resp?: { status_code?: number; status_msg?: string };
  };

  if (payload.base_resp?.status_code && payload.base_resp.status_code !== 0) {
    return jsonResponse({
      error: payload.base_resp.status_msg || "MiniMax TTS returned an error.",
      base_resp: payload.base_resp,
    }, 502);
  }

  if (!payload.data?.audio) {
    return jsonResponse({ error: "MiniMax TTS returned no audio." }, 502);
  }

  return new Response(hexToUint8Array(payload.data.audio), {
    status: 200,
    headers: { "content-type": "audio/mpeg" },
  });
}

async function handleVoices(env: Env, minimaxVoicesURL: string): Promise<Response> {
  const response = await fetch(minimaxVoicesURL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.MINIMAX_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({ voice_type: "all" }),
  });

  const responseText = await response.text();
  if (!response.ok) {
    console.error(`[/voices] MiniMax voice catalog error ${response.status}: ${responseText}`);
  }

  return new Response(responseText, {
    status: response.status,
    headers: { "content-type": "application/json" },
  });
}

async function handleTranscribeURL(request: Request, env: Env): Promise<Response> {
  const body: { keyterms?: string[] } = await request
    .json<{ keyterms?: string[] }>()
    .catch(() => ({}));
  const voiceId = crypto.randomUUID();
  const timestamp = Math.floor(Date.now() / 1000);
  const expired = timestamp + 600;
  const nonce = Math.floor(Math.random() * 1_000_000_000).toString();

  const params: Record<string, string> = {
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
  const signature = await hmacSha1Base64(signatureSource, env.TENCENT_ASR_SECRET_KEY);

  const finalQuery = new URLSearchParams(params);
  finalQuery.set("signature", signature);

  return jsonResponse({
    websocket_url: `wss://${TENCENT_ASR_HOST}${signedPath}?${finalQuery.toString()}`,
    voice_id: voiceId,
    expires_at: expired,
  });
}

function makeHotwordList(keyterms: string[]): string | null {
  const normalizedKeyterms = keyterms
    .map((term) => term.trim())
    .filter(Boolean)
    .slice(0, 128)
    .map((term) => `${term.replace(/[,\s|]/g, "")}|8`)
    .filter((term) => term.length > 2);

  return normalizedKeyterms.length > 0 ? normalizedKeyterms.join(",") : null;
}

function parseMiniMaxTTSVolume(rawVolume: string | number | undefined): number {
  const parsedVolume = Number(rawVolume || defaultMiniMaxTTSVolume);
  if (!Number.isFinite(parsedVolume)) {
    return defaultMiniMaxTTSVolume;
  }

  return Math.max(0.1, Math.min(parsedVolume, 10));
}

function parseMiniMaxTTSSpeed(rawSpeed: number | undefined): number {
  const parsedSpeed = Number(rawSpeed ?? 1);
  if (!Number.isFinite(parsedSpeed)) {
    return 1;
  }
  return Math.max(0.5, Math.min(parsedSpeed, 2));
}

function parseMiniMaxTTSPitch(rawPitch: number | undefined): number {
  const parsedPitch = Number(rawPitch ?? 0);
  if (!Number.isFinite(parsedPitch)) {
    return 0;
  }
  return Math.round(Math.max(-12, Math.min(parsedPitch, 12)));
}

function makeSortedQueryString(params: Record<string, string>): string {
  return Object.keys(params)
    .sort()
    .map((key) => `${key}=${params[key]}`)
    .join("&");
}

async function hmacSha1Base64(message: string, secret: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return arrayBufferToBase64(signature);
}

function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function hexToUint8Array(hex: string): Uint8Array {
  const normalizedHex = hex.trim();
  const bytes = new Uint8Array(normalizedHex.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = parseInt(normalizedHex.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}
