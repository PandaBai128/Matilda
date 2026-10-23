// Explicit opt-in live smoke test; excluded from npm test. Uses only the
// synthetic fixture and prints no credentials, reasoning, or desktop content.
import { readFileSync } from "node:fs";
import { createMiniMaxChatResponse } from "../minimax-chat.mjs";
import { refineComputerPoint } from "../minimax-pointing-precision.mjs";

const environment = {};
for (const filename of [".dev.vars", ".env"]) {
  try {
    for (const line of readFileSync(filename, "utf8").split(/\r?\n/)) {
      const match = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
      if (match) environment[match[1]] = match[2].replace(/^["']|["']$/g, "");
    }
  } catch (error) { if (error.code !== "ENOENT") throw error; }
}
Object.assign(environment, {
  MINIMAX_CHAT_MODEL: "MiniMax-M3.1-Flash", MINIMAX_THINKING_TYPE: "adaptive",
  MINIMAX_REASONING_EFFORT: "low", MINIMAX_MAX_TOKENS: "8192",
});
environment.MINIMAX_CHAT_MODEL = process.env.MATILDA_TEST_MODEL || environment.MINIMAX_CHAT_MODEL;
environment.MINIMAX_POINTING_MODE = process.env.MATILDA_TEST_POINTING_MODE || environment.MINIMAX_POINTING_MODE || "custom";
if (!environment.MINIMAX_API_KEY) throw new Error("Missing local MiniMax credentials.");
const fixture = readFileSync(process.argv[2] || "/private/tmp/matilda-grounding-fixture.png").toString("base64");
const personaSource = readFileSync("../leanring-buddy/MatildaCompanionPersona.swift", "utf8");
const personaPrompt = personaSource.match(/"""\n([\s\S]*?)\n\s*"""/)[1]
  .replace(/^ {8}/gm, "")
  .replace("\\(responseLengthInstruction)", "keep the reply to one or two short sentences.");
const cases = [
  { name: "small close control", prompt: "指一下 Studio Notes 窗口左上角红色关闭按钮。", box: [98, 106, 112, 120] },
  { name: "top-right save", prompt: "指一下窗口右上角的 Save 按钮。", box: [1160, 105, 1250, 137] },
  { name: "similar export controls", prompt: "指一下 Export CSV 按钮，不是 Export PDF。", box: [480, 420, 600, 458] },
  { name: "sidebar", prompt: "指一下左侧 Documents 导航项。", box: [96, 270, 282, 306] },
  { name: "desktop folder icon", prompt: "指一下桌面上 Research 文件夹的图标，不是名字。", box: [1330, 171, 1386, 226] },
  { name: "second display", prompt: "指一下第二个屏幕上窗口右下方的 Delete note 按钮。", box: [1140, 734, 1250, 770], screen: 2 },
  { name: "absent target", prompt: "指一下屏幕上名为 Publish 的按钮。", box: null },
];
const selectedCases = process.argv[3] ? cases.filter(testCase => testCase.name === process.argv[3]) : cases;
let failures = 0;
for (const testCase of selectedCases) {
  const started = performance.now();
  const imageBlock = { type: "image", source: { type: "base64", media_type: "image/png", data: fixture } };
  const content = [imageBlock, { type: "text", text: "screen 1 (primary focus)" }];
  if (testCase.screen === 2) content.push(imageBlock, { type: "text", text: "screen 2 (secondary screen)" });
  content.push({ type: "text", text: `${testCase.prompt}\n\ninternal clicky pointing requirement:\n- Return [POINT_V2:x,y:label] or [POINT_V2:none].` });
  const body = {
    model: "MiniMax-M3", max_tokens: 1024, stream: true, temperature: 0.1,
    system: personaPrompt,
    messages: [{ role: "user", content }],
  };
  const response = process.env.MATILDA_TEST_PROXY_URL
    ? await fetch(`${process.env.MATILDA_TEST_PROXY_URL}/chat`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify(body), signal: AbortSignal.timeout(90000),
    })
    : await createMiniMaxChatResponse(body, environment,
      `${(environment.MINIMAX_API_HOST || "https://api.minimax.io").replace(/\/+$/, "")}/anthropic/v1/messages`, {
        signal: AbortSignal.timeout(90000), refineComputerPoint,
      });
  if (!response.ok) {
    // Only status and API error code, never echoed request bodies or headers.
    const payload = await response.json().catch(() => ({}));
    console.log(JSON.stringify({ test: testCase.name, status: response.status, code: payload.base_resp?.status_code || payload.error?.type }));
    failures += 1;
    continue;
  }
  const stream = await response.text();
  let answer = "";
  for (const line of stream.split("\n")) {
    if (line.startsWith("data:")) answer += JSON.parse(line.slice(5)).delta?.text || "";
  }
  const match = answer.match(/\[POINT_V2:(\d+),(\d+):[^\]]*:screen(\d+)\]/);
  const point = match ? [Number(match[1]) * 1.44, Number(match[2]) * 0.9] : null;
  const box = testCase.box;
  const hit = box ? !!point && Number(match[3]) === (testCase.screen || 1)
    && point[0] >= box[0] && point[0] <= box[2] && point[1] >= box[1] && point[1] <= box[3]
    : answer.includes("[POINT_V2:none]");
  if (!hit) failures += 1;
  console.log(JSON.stringify({ test: testCase.name, hit, point, expectedBox: box, seconds: Number(((performance.now() - started) / 1000).toFixed(2)) }));
}
console.log(JSON.stringify({ model: environment.MINIMAX_CHAT_MODEL, effort: "low", pointingMode: environment.MINIMAX_POINTING_MODE, cases: selectedCases.length, failures }));
process.exitCode = failures ? 1 : 0;
