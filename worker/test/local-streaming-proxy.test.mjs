import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { Readable } from "node:stream";
import { test } from "node:test";
import {
  handleChat,
  handleStreamingTTS,
  miniMaxTTSModelSupportsEmotion,
  pipeMiniMaxStreamingAudioToNodeResponse,
} from "../local-server.mjs";

const encoder = new TextEncoder();

test("chat route sends M3.1 low effort and handles response backpressure", async () => {
  const request = Readable.from([Buffer.from(JSON.stringify({
    model: "MiniMax-M3", max_tokens: 1024, stream: true,
    messages: [{ role: "user", content: [{ type: "text", text: "你好" }] }],
  }))]);
  const response = new TestResponse();
  response.returnBackpressureOnce = true;
  let outgoingBody;
  const handling = handleChat(request, response, {
    environment: { MINIMAX_API_KEY: "test-key", MINIMAX_CHAT_MODEL: "MiniMax-M3.1-Flash", MINIMAX_THINKING_TYPE: "low" },
    fetchImplementation: async (_url, options) => {
      outgoingBody = JSON.parse(options.body);
      return new Response([
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好。"}}\n\n',
        'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\n',
        'data: {"type":"message_stop"}\n\n',
      ].join(""));
    },
  });
  while (!response.writes.length) await new Promise(resolve => setTimeout(resolve, 1));
  response.emit("drain");
  await handling;
  assert.equal(outgoingBody.output_config.effort, "low");
  assert.equal(outgoingBody.max_tokens, 8192);
  assert.ok(response.writableEnded);
  assert.ok(Buffer.concat(response.writes).toString().includes("你好。"));
});

test("local streaming proxy waits for response drain after backpressure", async () => {
  const response = new TestResponse();
  response.returnBackpressureOnce = true;
  const upstreamBody = new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode('data: {"data":{"audio":"61","status":1}}\n'));
      controller.enqueue(encoder.encode('data: {"data":{"audio":"62","status":1}}\n'));
      controller.close();
    },
  });
  const abortController = new AbortController();

  const pipingPromise = pipeMiniMaxStreamingAudioToNodeResponse(
    upstreamBody,
    response,
    abortController.signal,
  );
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(response.writes.length, 1);

  response.emit("drain");
  await pipingPromise;
  assert.deepEqual(response.writes.map((chunk) => chunk.toString()), ["a", "b"]);
});

test("local streaming proxy stops waiting for drain when cancelled", async () => {
  const response = new TestResponse();
  response.returnBackpressureOnce = true;
  let upstreamWasCancelled = false;
  const upstreamBody = new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode('data: {"data":{"audio":"61","status":1}}\n'));
    },
    cancel() {
      upstreamWasCancelled = true;
    },
  });
  const abortController = new AbortController();

  const pipingPromise = pipeMiniMaxStreamingAudioToNodeResponse(
    upstreamBody,
    response,
    abortController.signal,
  );
  await new Promise((resolve) => setTimeout(resolve, 10));
  abortController.abort();
  await pipingPromise;

  assert.equal(upstreamWasCancelled, true);
  assert.equal(response.writes.length, 1);
});

test("client response close aborts the MiniMax fetch and upstream reader", async () => {
  const request = Readable.from([Buffer.from(JSON.stringify({ text: "cancel me" }))]);
  request.method = "POST";
  request.headers = {};
  request.aborted = false;
  const response = new TestResponse();
  let fetchSignal;
  let upstreamWasCancelled = false;
  const upstreamBody = new ReadableStream({
    pull() {},
    cancel() {
      upstreamWasCancelled = true;
    },
  });
  const fetchImplementation = async (_url, options) => {
    fetchSignal = options.signal;
    return new Response(upstreamBody, { status: 200 });
  };

  const handlingPromise = handleStreamingTTS(request, response, {
    environment: { MINIMAX_API_KEY: "test-key" },
    fetchImplementation,
    ttsURL: "https://minimax.test/tts",
  });
  while (!fetchSignal) {
    await new Promise((resolve) => setTimeout(resolve, 1));
  }
  response.emit("close");
  await handlingPromise;

  assert.equal(fetchSignal.aborted, true);
  assert.equal(upstreamWasCancelled, true);
});

test("speech-2.8 does not expose unsupported emotion settings", () => {
  assert.equal(miniMaxTTSModelSupportsEmotion("speech-2.8-turbo"), false);
  assert.equal(miniMaxTTSModelSupportsEmotion("speech-2.6-turbo"), true);
  assert.equal(miniMaxTTSModelSupportsEmotion("speech-02-hd"), true);
});

class TestResponse extends EventEmitter {
  writes = [];
  returnBackpressureOnce = false;
  headersSent = false;
  writableEnded = false;
  destroyed = false;

  writeHead() {
    this.headersSent = true;
  }

  write(chunk) {
    this.writes.push(Buffer.from(chunk));
    if (this.returnBackpressureOnce) {
      this.returnBackpressureOnce = false;
      return false;
    }
    return true;
  }

  end() {
    this.writableEnded = true;
  }

  destroy() {
    this.destroyed = true;
  }
}
