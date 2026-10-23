// Opt-in replay against the running local proxy; no desktop capture or clicks.
// Usage: node test/check-live-pointing-followups.mjs <1920x1295 screenshot> [repetitions]
import { readFile, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';

const screenshotPath = process.argv[2];
const repetitions = Number(process.argv[3] || 1);
if (!screenshotPath || !Number.isInteger(repetitions) || repetitions < 1 || repetitions > 5) throw Error('Supply an approved fixture image and 1–5 repetitions.');
const imageBytes = await readFile(screenshotPath);
const { width, height } = await sharp(imageBytes).metadata();
if (width !== 1920 || height !== 1295) throw Error('Measured bounds require the 1920×1295 user replay.');
const jpeg = await sharp(imageBytes).resize({ width: 3072 }).jpeg({ quality: 80 }).toBuffer();
const image = { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: jpeg.toString('base64') } };
const csvHistory = [['Export CSV 按钮在哪，不是 PDF？', '在 Documents 的下面，Export PDF 右边，灰色的 Export CSV。']];
const saveHistory = [['演示文档的 Save 按钮在哪里？', '在演示文档窗口右上角。']];
const cases = [
  { name: 'natural-csv', history: csvHistory, prompt: '你指给我', legacySuffix: true, box: [760, 911, 884, 957] },
  { name: 'bare-csv', history: csvHistory, prompt: '指一下', box: [760, 911, 884, 957] },
  { name: 'clarification-csv', history: [...csvHistory, ['我没看到', '就是灰色的 Export CSV 按钮。']], prompt: '给我指一下', box: [760, 911, 884, 957] },
  { name: 'repeat-save', history: [...saveHistory, ['指给我', '位置在这里。']], prompt: '再指一次', box: [1663, 631, 1748, 672] },
  { name: 'close-followup', history: [['演示文档的红色关闭按钮在哪？', '在演示文档窗口左上角。']], prompt: '你指给我', circle: [421, 652, 9] },
  { name: 'new-target-overrides-save', history: saveHistory, prompt: '指一下 Export CSV 按钮，不是 Export PDF', box: [760, 911, 884, 957] },
  { name: 'latest-target-pdf', history: [...csvHistory, ['那 Export PDF 呢？', '它是左边蓝色的 Export PDF 按钮。']], prompt: '你指给我', box: [622, 911, 745, 957] },
  { name: 'absent-target', history: [['Publish 按钮在哪里？', '刚才提到的是 Publish 按钮。']], prompt: '你指给我', absent: true },
  { name: 'unestablished-target', history: [['你好', '嗯，我在。']], prompt: '你指给我', absent: true, clarification: true },
  { name: 'target-six-exchanges-back', history: [...csvHistory,
    ['下面有两个', '嗯，一个蓝色，一个灰色。'], ['哪个颜色', '你要找的是灰色的。'],
    ['右边吗', '对，右边。'], ['我没看清', '可以，我给你指。'], ['好', '我在。']],
    prompt: '你指给我', box: [760, 911, 884, 957] },
];
const results = [];
const outputDirectory = await mkdtemp(join(tmpdir(), 'matilda-followup-validation-'));
console.log(JSON.stringify({ outputDirectory }));
for (const item of cases.filter(item => !process.env.MATILDA_TEST_CASE || item.name === process.env.MATILDA_TEST_CASE)) for (let attempt = 1; attempt <= repetitions; attempt++) {
  const started = performance.now();
  try {
    const messages = item.history.flatMap(([user, assistant]) => [{ role: 'user', content: user }, { role: 'assistant', content: assistant }]);
    messages.push({ role: 'user', content: [image, { type: 'text', text: `${item.prompt}\n\n${item.legacySuffix
      ? 'internal clicky requirement: this is not a pointing request. answer normally.' : 'internal clicky pointing requirement: Return a normalized V2 target.'}` }] });
    const response = await fetch('http://localhost:8787/chat', { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'MiniMax-M3.1-Flash', max_tokens: 8192, stream: true, temperature: 0.1, messages }), signal: AbortSignal.timeout(120000) });
    if (!response.ok) throw Error(`Proxy HTTP ${response.status}`);
    const text = (await response.text()).split('\n').filter(line => line.startsWith('data:'))
      .map(line => JSON.parse(line.slice(5)).delta?.text || '').join('');
    const match = text.match(/\[POINT_V2:(\d+),(\d+):[^\]]*:screen(\d+)\]/);
    const point = match ? [Number(match[1]) * width / 1000, Number(match[2]) * height / 1000] : null;
    const passed = item.absent ? !point && text.includes('[POINT_V2:none]') && (!item.clarification || text.includes('哪个'))
      : !!point && Number(match[3]) === 1 && (item.circle ? Math.hypot(point[0] - item.circle[0], point[1] - item.circle[1]) <= item.circle[2]
        : point[0] >= item.box[0] && point[0] <= item.box[2] && point[1] >= item.box[1] && point[1] <= item.box[3]);
    const expectedCenter = item.circle || (item.box && [(item.box[0] + item.box[2]) / 2, (item.box[1] + item.box[3]) / 2]);
    results.push({ name: item.name, attempt, passed, point, centerError: point && expectedCenter ? Math.hypot(point[0] - expectedCenter[0], point[1] - expectedCenter[1]) : null,
      seconds: Number(((performance.now() - started) / 1000).toFixed(2)) });
  } catch (error) { results.push({ name: item.name, attempt, passed: false, error: error.message }); }
  console.log(JSON.stringify(results.at(-1)));
  await writeFile(join(outputDirectory, 'results.json'), JSON.stringify(results, null, 2));
}
console.log(JSON.stringify({ passed: results.filter(result => result.passed).length, total: results.length, outputDirectory }));
process.exitCode = results.every(result => result.passed) ? 0 : 1;
