// Explicit live replay of user-supplied screenshots; never captures the desktop.
// Usage: node test/check-live-user-grounding.mjs <folder> [repetitions]
import { readFileSync } from "node:fs";
import { createMiniMaxChatResponse } from "../minimax-chat.mjs";
import sharp from 'sharp';
import { refineComputerPoint } from '../minimax-pointing-precision.mjs';

const environment = {};
for (const line of readFileSync('.dev.vars', 'utf8').split(/\r?\n/)) {
  const match = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
  if (match) environment[match[1]] = match[2].replace(/^["']|["']$/g, '');
}
environment.MINIMAX_POINTING_MODE = process.env.MATILDA_TEST_POINTING_MODE || 'computer';
environment.MINIMAX_REASONING_EFFORT = process.env.MATILDA_TEST_EFFORT || 'low';
environment.MINIMAX_POINTING_PRECISION = process.env.MATILDA_TEST_PRECISION || 'raw';
const repetitions = Number(process.argv[3] || 3);
if (!process.argv[2] || !Number.isInteger(repetitions) || repetitions < 1 || repetitions > 10) throw Error('Supply screenshot folder and 1–10 repetitions.');
const cases = [
  { name: 'save', prompt: '指一下下方“演示文档”窗口右上角的 Save 按钮。', box: [1663, 631, 1748, 672] },
  { name: 'close', prompt: '指一下演示文档窗口左上角红色的关闭按钮。', box: [412, 643, 430, 661], circle: [421, 652, 9] },
  { name: 'csv', prompt: '指一下 Export CSV 按钮，不是 Export PDF。', box: [760, 911, 884, 957] },
];
let hits = 0;
for (const item of cases) {
  const png = readFileSync(`${process.argv[2]}/${item.name}.png`);
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
  const jpeg = process.env.MATILDA_TEST_JPEG === '1';
  const imageBytes = jpeg ? await sharp(png).resize({ width: 3072 }).jpeg({ quality: 80 }).toBuffer() : png;
  if (width !== 1920 || height !== 1295) throw Error('These measured target bounds require the supplied 1920×1295 screenshots.');
  for (let attempt = 1; attempt <= repetitions; attempt++) {
    const started = performance.now();
    const body = { model: environment.MINIMAX_CHAT_MODEL, stream: true, max_tokens: 8192, temperature: Number(process.env.MATILDA_TEST_TEMPERATURE || 0.1),
      messages: [{ role: 'user', content: [
        { type: 'image', source: { type: 'base64', media_type: jpeg ? 'image/jpeg' : 'image/png', data: imageBytes.toString('base64') } },
        { type: 'text', text: `${item.prompt}\n\ninternal clicky pointing requirement:\nReturn a normalized V2 target.` },
      ] }],
    };
    const response = await createMiniMaxChatResponse(body, environment,
      `${environment.MINIMAX_API_HOST || 'https://api.minimax.io'}/anthropic/v1/messages`, { signal: AbortSignal.timeout(90000), refineComputerPoint });
    if (!response.ok) throw Error(`Upstream HTTP ${response.status}`);
    const stream = await response.text();
    const text = stream.split('\n').filter(line => line.startsWith('data:'))
      .map(line => JSON.parse(line.slice(5)).delta?.text || '').join('');
    const match = text.match(/\[POINT_V2:(\d+),(\d+):[^\]]*:screen(\d+)\]/);
    const point = match ? [Number(match[1]) * width / 1000, Number(match[2]) * height / 1000] : null;
    const hit = !!point && Number(match[3]) === 1 && (item.circle
      ? Math.hypot(point[0] - item.circle[0], point[1] - item.circle[1]) <= item.circle[2]
      : point[0] >= item.box[0] && point[0] <= item.box[2] && point[1] >= item.box[1] && point[1] <= item.box[3]);
    if (hit) hits++;
    console.log(JSON.stringify({ case: item.name, attempt, hit, point, expectedBox: item.box,
      centerError: point ? Math.hypot(point[0] - (item.box[0] + item.box[2]) / 2, point[1] - (item.box[1] + item.box[3]) / 2) : null,
      seconds: Number(((performance.now() - started) / 1000).toFixed(2)) }));
  }
}
console.log(JSON.stringify({ mode: environment.MINIMAX_POINTING_MODE, effort: environment.MINIMAX_REASONING_EFFORT, hits, total: cases.length * repetitions }));
process.exitCode = hits === cases.length * repetitions ? 0 : 1;
