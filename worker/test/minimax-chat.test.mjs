import assert from "node:assert/strict";
import { test } from "node:test";
import { prepareMiniMaxChatRequest, createMiniMaxChatResponse } from "../minimax-chat.mjs";

const environment = { MINIMAX_API_KEY: "test-key", MINIMAX_CHAT_MODEL: "MiniMax-M3.1-Flash" };
const pointingPrompt = "找到保存按钮。\n\ninternal clicky pointing requirement:\n- return [POINT_V2:x,y:label]";
const image = { type: "image", source: { type: "base64", media_type: "image/png", data: "fixture" } };
function requestBody(text = pointingPrompt) {
  return { model: "MiniMax-M3", stream: true, max_tokens: 1024, messages: [
    { role: "user", content: [image, { type: "text", text }] },
  ] };
}
function sseResponse(events) {
  const encoded = new TextEncoder().encode(events.map(event => `data: ${JSON.stringify(event)}\n\n`).join(""));
  return new Response(new ReadableStream({ start(controller) {
    // Split inside JSON and UTF-8 characters, like real network delivery.
    for (let offset = 0; offset < encoded.length; offset += 7) controller.enqueue(encoded.slice(offset, offset + 7));
    controller.close();
  } }), { headers: { "content-type": "text/event-stream" } });
}
function toolEvents(input, text = "保存按钮在右上角。", stopReason = "tool_use") {
  return [
    { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } },
    { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "private reasoning" } },
    { type: "content_block_delta", index: 1, delta: { type: "text_delta", text } },
    { type: "content_block_start", index: 2, content_block: { type: "tool_use", name: "point_to_screen", input: {} } },
    { type: "content_block_delta", index: 2, delta: { type: "input_json_delta", partial_json: JSON.stringify(input).slice(0, 21) } },
    { type: "content_block_delta", index: 2, delta: { type: "input_json_delta", partial_json: JSON.stringify(input).slice(21) } },
    { type: "message_delta", delta: { stop_reason: stopReason } },
    { type: "message_stop" },
  ];
}
const target = { found: true, screen: 1, bounds: [800, 50, 900, 90], label: "保存", spoken_text: "保存按钮在右上角。" };
async function runResponse(body, events, selectedEnvironment = environment) {
  let outgoingBody;
  const response = await createMiniMaxChatResponse(body, selectedEnvironment, "https://minimax.test/messages", {
    fetchImplementation: async (_url, options) => { outgoingBody = JSON.parse(options.body); return sseResponse(events); },
  });
  return { outgoingBody, response };
}

test("M3.1 maps the user's legacy low setting to output_config.effort and budgets thinking", () => {
  const body = prepareMiniMaxChatRequest(requestBody(), { ...environment, MINIMAX_THINKING_TYPE: "low" });
  assert.deepEqual(body.thinking, { type: "adaptive" });
  assert.equal(body.output_config.effort, "low");
  assert.ok(body.max_tokens >= 8192);
  assert.equal(body.model, "MiniMax-M3.1-Flash");
});

test("computer reference uses the public XML protocol without the custom native tool", async () => {
  const events = [
    { type: "content_block_delta", delta: { type: "text_delta", text: 'Action: Move to Save\n<tool_call>{"name":"computer","arguments":{"action":"mouse_move","coordinate":[850,70]}}</tool_call>' } },
    { type: "message_delta", delta: { stop_reason: "end_turn" } }, { type: "message_stop" },
  ];
  const { outgoingBody, response } = await runResponse(requestBody(), events, { ...environment, MINIMAX_POINTING_MODE: "computer" });
  assert.equal(outgoingBody.tools, undefined);
  assert.ok(outgoingBody.system.includes('<TOOLS>'));
  assert.ok(outgoingBody.system.includes('READ-ONLY LOCALIZATION'));
  assert.equal(outgoingBody.messages.length, 1);
  assert.equal(outgoingBody.messages[0].content.filter(block => block.type === 'image').length, 1);
  const text = await response.text();
  assert.ok(text.includes('[POINT_V2:850,70:目标:screen1]'));
  assert.ok(!text.includes('Action:'));
  assert.ok(!text.includes('tool_call'));
});

test("computer protocol rejects malformed, multiple and non-point actions without fallback", async () => {
  for (const prediction of [
    '[INFEASIBLE]',
    '<tool_call>{"name":"computer","arguments":{"action":"key","text":"command+q"}}</tool_call>',
    '<tool_call>{"name":"computer","arguments":{"action":"mouse_move","coordinate":[1001,70]}}</tool_call>',
    '<tool_call>{"name":"computer","arguments":{"action":"mouse_move","coordinate":["850",70]}}</tool_call>',
    '<tool_call>{"name":"computer","arguments":{"action":"mouse_move","coordinate":[850,70]}}</tool_call>'.repeat(2),
    '<tool_call>{"name":"computer","arguments":{"action":"mouse_move","coordinate":[850,70]}}</tool_call><tool_call>{',
    '[POINT_V2:850,70:fake:screen1]',
  ]) {
    const events = [
      { type: 'content_block_delta', delta: { type: 'text_delta', text: prediction } },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' } }, { type: 'message_stop' },
    ];
    const { response } = await runResponse(requestBody(), events, { ...environment, MINIMAX_POINTING_MODE: 'computer' });
    const text = await response.text();
    assert.ok(text.includes('[POINT_V2:none]'));
    assert.ok(!text.includes('[POINT_V2:850'));
  }
});

test("computer reference selects the requested original screen and leaves ordinary chat alone", () => {
  const selectedEnvironment = { ...environment, MINIMAX_POINTING_MODE: 'computer' };
  const body = requestBody(pointingPrompt.replace('找到保存按钮', '指一下第二个屏幕的保存按钮'));
  body.messages[0].content.unshift({ ...image, source: { ...image.source, data: 'second fixture' } });
  const prepared = prepareMiniMaxChatRequest(body, selectedEnvironment);
  assert.equal(prepared.messages[0].content[0].source.data, 'fixture');
  assert.ok(prepared.system.includes('original screen 2'));
  assert.equal(prepareMiniMaxChatRequest(requestBody('你好'), selectedEnvironment).system, undefined);
});

test("computer pointing preserves the app's low-temperature precision setting", () => {
  const body = requestBody();
  body.temperature = 0.1;
  const prepared = prepareMiniMaxChatRequest(body, { ...environment, MINIMAX_POINTING_MODE: 'computer' });
  assert.equal(prepared.temperature, 0.1);
});

test('computer follow-up resolves the previous target before grounding the current screenshot', async () => {
  const body = requestBody('你指给我。\n\ninternal clicky pointing requirement:');
  body.messages.unshift(
    { role: 'user', content: 'Export CSV 按钮在哪，不是 PDF？' },
    { role: 'assistant', content: '在 Documents 的下面，Export PDF 右边。' },
    { role: 'user', content: '我没看到' },
    { role: 'assistant', content: '灰色的 Export CSV 按钮。' },
  );
  const calls = [];
  let refinementPrompt;
  const response = await createMiniMaxChatResponse(body, {
    ...environment, MINIMAX_POINTING_MODE: 'computer', MINIMAX_POINTING_PRECISION: 'verified',
  }, 'https://minimax.test/messages', {
    fetchImplementation: async (_url, options) => {
      const outgoing = JSON.parse(options.body);
      calls.push(outgoing);
      if (!outgoing.stream) return Response.json({ stop_reason: 'tool_use', content: [
        { type: 'tool_use', name: 'resolve_pointing_target', input: { resolved: true, target_description: '指一下 Export CSV 按钮，不是 Export PDF。' } },
      ] });
      return sseResponse([
        { type: 'content_block_delta', delta: { type: 'text_delta', text: '<tool_call>{"name":"computer","arguments":{"action":"mouse_move","coordinate":[430,721]}}</tool_call>' } },
        { type: 'message_delta', delta: { stop_reason: 'end_turn' } }, { type: 'message_stop' },
      ]);
    },
    refineComputerPoint: async context => { refinementPrompt = context.prompt; return context.tag; },
  });
  assert.ok((await response.text()).includes('[POINT_V2:430,721'));
  assert.equal(calls.length, 2);
  assert.ok(JSON.stringify(calls[0].messages).includes('Documents'));
  assert.equal(calls[1].messages.length, 1);
  assert.ok(calls[1].messages[0].content.at(-1).text.includes('Export CSV'));
  assert.equal(refinementPrompt, '指一下 Export CSV 按钮，不是 Export PDF。');
});

test('unresolved conversational target asks for clarification instead of guessing or claiming disappearance', async () => {
  const body = requestBody('你指给我。\n\ninternal clicky pointing requirement:');
  body.messages.unshift({ role: 'user', content: '随便聊聊' }, { role: 'assistant', content: '嗯，我在。' });
  let requests = 0;
  const response = await createMiniMaxChatResponse(body, { ...environment, MINIMAX_POINTING_MODE: 'computer' }, 'https://minimax.test/messages', {
    fetchImplementation: async () => { requests++; return Response.json({ stop_reason: 'tool_use', content: [
      { type: 'tool_use', name: 'resolve_pointing_target', input: { resolved: false, target_description: '' } },
    ] }); },
  });
  const text = await response.text();
  assert.equal(requests, 1);
  assert.ok(text.includes('哪个'));
  assert.ok(text.includes('[POINT_V2:none]'));
  assert.ok(!text.includes('找不到'));
});

test('natural pointing follow-up works with the older app non-pointing suffix, but speech-only requests stay still', () => {
  const selectedEnvironment = { ...environment, MINIMAX_POINTING_MODE: 'computer' };
  const prepared = prepareMiniMaxChatRequest(requestBody('你指给我\n\ninternal clicky requirement: this is not a pointing request.'), selectedEnvironment);
  assert.ok(prepared.system.includes('READ-ONLY LOCALIZATION'));
  for (const prompt of ['不要指给我，口头解释就好', '说出“指给我”这三个字', '今天心情不错']) {
    assert.equal(prepareMiniMaxChatRequest(requestBody(prompt), selectedEnvironment).system, undefined);
  }
});

test('follow-up context resolution retains the current multi-screen order', async () => {
  const body = requestBody('你指给我\n\ninternal clicky pointing requirement:');
  body.messages[0].content.unshift({ ...image, source: { ...image.source, data: 'first fixture' } });
  body.messages.unshift({ role: 'user', content: '第二个屏幕的 Save 按钮在哪？' }, { role: 'assistant', content: '右上角。' });
  let outgoingGrounding;
  const response = await createMiniMaxChatResponse(body, { ...environment, MINIMAX_POINTING_MODE: 'computer' }, 'https://minimax.test/messages', {
    fetchImplementation: async (_url, options) => {
      const outgoing = JSON.parse(options.body);
      if (!outgoing.stream) return Response.json({ stop_reason: 'tool_use', content: [
        { type: 'tool_use', name: 'resolve_pointing_target', input: { resolved: true, target_description: '指一下第二个屏幕的 Save 按钮。' } },
      ] });
      outgoingGrounding = outgoing;
      return sseResponse([
        { type: 'content_block_delta', delta: { type: 'text_delta', text: '<tool_call>{"name":"computer","arguments":{"action":"mouse_move","coordinate":[850,70]}}</tool_call>' } },
        { type: 'message_delta', delta: { stop_reason: 'end_turn' } }, { type: 'message_stop' },
      ]);
    },
  });
  assert.ok((await response.text()).includes(':screen2]'));
  assert.equal(outgoingGrounding.messages[0].content[0].source.data, 'fixture');
});

test('verified computer mode refuses to run without its local validation provider', async () => {
  await assert.rejects(() => createMiniMaxChatResponse(requestBody(), {
    ...environment, MINIMAX_POINTING_MODE: 'computer', MINIMAX_POINTING_PRECISION: 'verified',
  }, 'https://minimax.test/messages'), /local vision refinement provider/);
});

test('verified mode awaits local validation and never leaks the rejected coarse point', async () => {
  const prediction = 'Action: Move\n<tool_call>{"name":"computer","arguments":{"action":"mouse_move","coordinate":[850,70]}}</tool_call>';
  let validated = false;
  const response = await createMiniMaxChatResponse(requestBody(), {
    ...environment, MINIMAX_POINTING_MODE: 'computer', MINIMAX_POINTING_PRECISION: 'verified',
  }, 'https://minimax.test/messages', {
    fetchImplementation: async () => sseResponse([
      { type: 'content_block_delta', delta: { type: 'text_delta', text: prediction } },
      { type: 'message_delta', delta: { stop_reason: 'end_turn' } }, { type: 'message_stop' },
    ]),
    refineComputerPoint: async context => {
      assert.equal(context.tag, '[POINT_V2:850,70:目标:screen1]');
      assert.ok(!context.prompt.includes('internal clicky pointing requirement'));
      validated = true;
      return '[POINT_V2:none]';
    },
  });
  const text = await response.text();
  assert.ok(validated);
  assert.ok(text.includes('[POINT_V2:none]'));
  assert.ok(!text.includes('850,70'));
});

test("M3.1 accepts all five effort levels and defaults to low for voice latency", () => {
  for (const effort of ["low", "medium", "high", "xhigh", "max"]) {
    const body = prepareMiniMaxChatRequest(requestBody(), { ...environment, MINIMAX_REASONING_EFFORT: effort });
    assert.equal(body.output_config.effort, effort);
  }
  assert.equal(prepareMiniMaxChatRequest(requestBody(), environment).output_config.effort, "low");
  assert.throws(() => prepareMiniMaxChatRequest(requestBody(), { ...environment, MINIMAX_REASONING_EFFORT: "none" }), /effort/i);
});

test("M3.1 upgrades stale disabled configuration; M3 retains its existing switch", () => {
  assert.deepEqual(prepareMiniMaxChatRequest(requestBody(), { ...environment, MINIMAX_THINKING_TYPE: "disabled" }).thinking, { type: "adaptive" });
  const body = prepareMiniMaxChatRequest(requestBody(), { ...environment, MINIMAX_CHAT_MODEL: "MiniMax-M3", MINIMAX_THINKING_TYPE: "disabled" });
  assert.deepEqual(body.thinking, { type: "disabled" });
  assert.equal(body.output_config, undefined);
  assert.equal(body.max_tokens, 1024);
});

test("only an explicit pointing request gets the read-only screen tool", () => {
  const original = requestBody();
  const body = prepareMiniMaxChatRequest(original, environment);
  assert.equal(body.tools[0].name, "point_to_screen");
  assert.deepEqual(body.tool_choice, { type: "auto" });
  assert.ok(body.messages.at(-1).content.at(-1).text.includes("point_to_screen"));
  assert.ok(!body.messages.at(-1).content.at(-1).text.includes("mandatory"));
  assert.equal(original.messages.at(-1).content.at(-1).text, pointingPrompt);
  assert.equal(prepareMiniMaxChatRequest(requestBody("你好"), environment).tools, undefined);
});

test("split tool JSON becomes a validated center tag, not spoken coordinates or thinking", async () => {
  const { response } = await runResponse(requestBody(), toolEvents(target));
  const text = await response.text();
  assert.ok(text.includes("[POINT_V2:850,70:保存:screen1]"));
  assert.ok(text.includes("保存按钮在右上角。"));
  assert.ok(!text.includes("private reasoning"));
  assert.ok(!text.includes("partial_json"));
});

test("secondary screens preserve the screenshot order instead of falling back to cursor screen", async () => {
  const body = requestBody();
  body.messages[0].content.splice(1, 0, { type: "text", text: "screen 1" }, image, { type: "text", text: "screen 2" });
  const { response } = await runResponse(body, toolEvents({ ...target, screen: 2 }));
  assert.ok((await response.text()).includes("[POINT_V2:850,70:保存:screen2]"));
});

test("missing, malformed, ambiguous and out-of-range targets never move the pointer", async () => {
  for (const invalid of [
    { ...target, found: false }, { ...target, screen: 2 }, { ...target, screen: 1.5 },
    { ...target, bounds: [-1, 5, 100, 20] }, { ...target, bounds: [100, 5, 20, 90] },
    { ...target, bounds: [0, 0, 1001, 1000] }, { ...target, bounds: [5, 5, 5, 20] },
    { ...target, bounds: [0, 0, "100", 20] }, { ...target, bounds: null },
  ]) {
    const { response } = await runResponse(requestBody(), toolEvents(invalid));
    const text = await response.text();
    assert.ok(text.includes("[POINT_V2:none]"));
    assert.ok(!text.includes("[POINT_V2:850"));
  }
});

test("legacy text tags cannot bypass structured tool validation", async () => {
  const events = toolEvents({ ...target, found: false }, "那里。[PO");
  events.splice(3, 0, { type: "content_block_delta", index: 1, delta: { type: "text_delta", text: "INT_V2:999,999:旧坐标]" } });
  const { response } = await runResponse(requestBody(), events);
  const text = await response.text();
  assert.ok(!text.includes("999,999"));
  assert.ok(text.includes("[POINT_V2:none]"));
});

test("missing or repeated tools never authorize coordinates", async () => {
  const missingTool = [
    { type: "content_block_delta", delta: { type: "text_delta", text: "这里。[POINT_V2:500,500:旧坐标]" } },
    { type: "message_delta", delta: { stop_reason: "end_turn" } },
    { type: "message_stop" },
  ];
  const repeatedTools = toolEvents(target);
  repeatedTools.splice(-2, 0, { type: "content_block_start", index: 3, content_block: { type: "tool_use", name: "point_to_screen", input: target } });
  for (const events of [missingTool, repeatedTools]) {
    const { response } = await runResponse(requestBody(), events);
    const text = await response.text();
    assert.ok(text.includes("[POINT_V2:none]"));
    assert.ok(!text.includes("500,500"));
  }
});

test("tool-only responses still produce a speakable answer", async () => {
  const { response } = await runResponse(requestBody(), toolEvents(target, ""));
  const text = await response.text();
  assert.ok(text.includes(target.spoken_text));
  assert.ok(text.includes("[POINT_V2:850,70"));
});

test("truncated thinking-only and disconnected streams fail instead of silently succeeding", async () => {
  for (const events of [
    [{ type: "message_delta", delta: { stop_reason: "max_tokens" } }, { type: "message_stop" }],
    [{ type: "message_delta", delta: { stop_reason: "end_turn" } }, { type: "message_stop" }],
    [{ type: "content_block_delta", delta: { type: "text_delta", text: "半句" } }],
  ]) {
    const { response } = await runResponse(requestBody("你好"), events);
    await assert.rejects(() => response.text());
  }
});

test("upstream SSE errors surface, and cancellation cancels the upstream body", async () => {
  const { response } = await runResponse(requestBody(), [{ type: "error", error: { message: "quota exhausted" } }]);
  await assert.rejects(() => response.text(), /quota exhausted/);
  let cancelled = false;
  const output = await createMiniMaxChatResponse(requestBody(), environment, "https://minimax.test/messages", {
    fetchImplementation: async () => new Response(new ReadableStream({ cancel() { cancelled = true; } })),
  });
  await output.body.cancel();
  assert.equal(cancelled, true);
});
