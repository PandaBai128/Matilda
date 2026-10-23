// Opt-in live regression: generated non-destructive variants, no desktop capture.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import sharp from 'sharp';
import { createMiniMaxChatResponse } from '../minimax-chat.mjs';
import { refineComputerPoint } from '../minimax-pointing-precision.mjs';
const inputFolder = process.argv[2];
if (!inputFolder) throw Error('Supply the replay-image folder.');
const environment = {};
for (const line of readFileSync('.dev.vars', 'utf8').split(/\r?\n/)) {
  const match = line.match(/^\s*([A-Z_]+)\s*=\s*(.*?)\s*$/);
  if (match) environment[match[1]] = match[2].replace(/^["']|["']$/g, '');
}
environment.MINIMAX_POINTING_MODE = 'computer';
environment.MINIMAX_POINTING_PRECISION = 'verified';
const folder = mkdtempSync('/private/tmp/matilda-variants-');
const baseline = readFileSync(`${inputFolder}/csv.png`);
const definitions = [
  { name: 'save', prompt: '指一下演示文档窗口右上角的 Save 按钮。', box: [1663, 631, 1748, 672] },
  { name: 'close', prompt: '指一下演示文档窗口左上角红色的关闭按钮。', box: [412, 643, 430, 661], circle: true },
  { name: 'csv', prompt: '指一下 Export CSV 按钮，不是 Export PDF。', box: [760, 911, 884, 957] },
];
const tasks = [];
async function add(name, family, prompt, image, box, circle = false) {
  const path = `${folder}/${name}.png`;
  await sharp(image).png().toFile(path);
  tasks.push({ name, family, prompt, path, box, circle });
}
const pdfTile = await sharp(baseline).extract({ left: 620, top: 909, width: 128, height: 50 }).toBuffer();
const csvTile = await sharp(baseline).extract({ left: 758, top: 909, width: 128, height: 50 }).toBuffer();
const swapped = await sharp(baseline).composite([{ input: csvTile, left: 620, top: 909 }, { input: pdfTile, left: 758, top: 909 }]).png().toBuffer();
await add('csv-swapped', 'csv', definitions[2].prompt, swapped, [622, 911, 746, 957]);
await add('pdf-swapped', 'csv', '指一下 Export PDF 按钮，不是 Export CSV。', swapped, [760, 911, 884, 957]);
const movedWindow = await sharp(baseline).extract({ left: 394, top: 619, width: 1372, height: 561 }).toBuffer();
const moved = await sharp(baseline).composite([
  { input: { create: { width: 1372, height: 561, channels: 3, background: '#6b8099' } }, left: 394, top: 619 },
  { input: movedWindow, left: 434, top: 639 },
]).png().toBuffer();
for (const definition of definitions) {
  await add(`${definition.name}-shifted`, definition.name, definition.prompt, moved,
    definition.box.map((value, index) => value + (index % 2 === 0 ? 40 : 20)), definition.circle);
  const scaled = await sharp(baseline).resize(1536, 1036).extend({ left: 192, right: 192, top: 129, bottom: 130, background: '#fafafa' }).png().toBuffer();
  await add(`${definition.name}-small`, definition.name, definition.prompt, scaled,
    definition.box.map((value, index) => value * 0.8 + (index % 2 === 0 ? 192 : 129)), definition.circle);
}
await add('absent-publish', 'csv', '指一下演示文档窗口中的 Publish 按钮。', baseline, null);
const results = [];
for (const task of tasks) {
  const image = await sharp(task.path).resize({ width: 3072 }).jpeg({ quality: 80 }).toBuffer();
  for (let attempt = 1; attempt <= 3; attempt++) {
    const started = performance.now();
    const response = await createMiniMaxChatResponse({ stream: true, max_tokens: 8192, temperature: 0.1,
      messages: [{ role: 'user', content: [
        { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: image.toString('base64') } },
        { type: 'text', text: `${task.prompt}\n\ninternal clicky pointing requirement:\nReturn one V2 target.` },
      ] }] }, environment, `${environment.MINIMAX_API_HOST}/anthropic/v1/messages`,
    { signal: AbortSignal.timeout(90000), refineComputerPoint });
    if (!response.ok) throw Error(`Upstream HTTP ${response.status}`);
    const text = (await response.text()).split('\n').filter(line => line.startsWith('data:'))
      .map(line => JSON.parse(line.slice(5)).delta?.text || '').join('');
    const match = text.match(/\[POINT_V2:(\d+),(\d+):[^\]]*:screen1\]/);
    const point = match ? [Number(match[1]) * 1.92, Number(match[2]) * 1.295] : null;
    const center = task.box && [(task.box[0] + task.box[2]) / 2, (task.box[1] + task.box[3]) / 2];
    const centerError = point && center ? Math.hypot(point[0] - center[0], point[1] - center[1]) : null;
    const hit = task.box ? !!point && (task.circle ? centerError <= (task.box[2] - task.box[0]) / 2
      : point[0] >= task.box[0] && point[0] <= task.box[2] && point[1] >= task.box[1] && point[1] <= task.box[3])
      : text.includes('[POINT_V2:none]');
    const result = { name: task.name, family: task.family, path: task.path, prompt: task.prompt,
      attempt, hit, point, expectedBox: task.box, centerError, seconds: (performance.now() - started) / 1000 };
    results.push(result);
    console.log(JSON.stringify(result));
    writeFileSync(`${folder}/results.json`, JSON.stringify(results, null, 2));
  }
}
const summary = { folder, total: results.length, hits: results.filter(result => result.hit).length,
  maximumCenterError: Math.max(...results.map(result => result.centerError || 0)) };
console.log(JSON.stringify(summary));
process.exitCode = results.every(result => result.hit && (result.centerError === null || result.centerError <= 4)) ? 0 : 1;
