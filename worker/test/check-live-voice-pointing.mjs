// Synthetic speech only. No microphone, user audio or desktop capture.
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { explicitControlText } from '../minimax-pointing-precision.mjs';
const execute = promisify(execFile);
const folder = mkdtempSync('/private/tmp/matilda-voice-replay-');
const prompts = ['指一下演示文档窗口右上角的 Save 按钮。',
  '指一下演示文档窗口左上角红色的关闭按钮。', '指一下 Export CSV 按钮，不是 Export PDF。'];
for (const [index, text] of prompts.entries()) {
  const tts = await fetch('http://127.0.0.1:8787/tts', { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ text, speed: 1 }), signal: AbortSignal.timeout(45000) });
  if (!tts.ok) throw Error(`TTS HTTP ${tts.status}`);
  writeFileSync(`${folder}/${index}.mp3`, Buffer.from(await tts.arrayBuffer()));
  await execute('/opt/homebrew/bin/ffmpeg', ['-v', 'error', '-i', `${folder}/${index}.mp3`, '-f', 's16le', '-acodec', 'pcm_s16le', '-ar', '16000', '-ac', '1', `${folder}/${index}.pcm`]);
  const signed = await fetch('http://127.0.0.1:8787/transcribe-url', { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ keyterms: ['Save', 'Export CSV', 'Export PDF'] }), signal: AbortSignal.timeout(10000) });
  if (!signed.ok) throw Error(`ASR URL HTTP ${signed.status}`);
  const payload = await signed.json();
  const socket = new WebSocket(payload.websocket_url);
  const sentences = new Map();
  let readyResolve, completeResolve, completeReject;
  const ready = new Promise(resolve => { readyResolve = resolve; });
  const completed = new Promise((resolve, reject) => { completeResolve = resolve; completeReject = reject; });
  const timeout = setTimeout(() => { socket.close(); completeReject(Error('ASR timed out.')); }, 30000);
  socket.onmessage = event => {
    const message = JSON.parse(String(event.data));
    if (message.code) { completeReject(Error(`ASR code ${message.code}`)); return; }
    readyResolve();
    if (message.result?.voice_text_str) sentences.set(message.result.index, message.result.voice_text_str);
    if (message.final === 1) completeResolve([...sentences.entries()].sort((first, second) => first[0] - second[0]).map(item => item[1]).join(''));
  };
  socket.onerror = () => completeReject(Error('ASR WebSocket failed.'));
  const transcriptPromise = (async () => {
    await ready;
    const audio = Buffer.concat([readFileSync(`${folder}/${index}.pcm`), Buffer.alloc(32000)]);
    for (let offset = 0; offset < audio.length; offset += 6400) {
      socket.send(audio.subarray(offset, offset + 6400));
      await new Promise(resolve => setTimeout(resolve, 200));
    }
    socket.send(JSON.stringify({ type: 'end' }));
    return completed;
  })();
  try {
    const transcript = await Promise.race([transcriptPromise, completed]);
    console.log(JSON.stringify({ test: index + 1, syntheticTranscript: transcript, positiveControl: explicitControlText(transcript) }));
  } finally { clearTimeout(timeout); socket.close(); }
}
