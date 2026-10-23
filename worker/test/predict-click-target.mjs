// Produces click coordinates for an isolated native test window. It never clicks.
import { readFileSync, writeFileSync } from 'node:fs';
import sharp from 'sharp';
const [filename, prompt, outputFile] = process.argv.slice(2);
if (!filename || !prompt) throw Error('Supply the test-window PNG and pointing instruction.');
const image = readFileSync(filename);
const { width, height } = await sharp(image).metadata();
const response = await fetch(`${process.env.MATILDA_TEST_PROXY_URL || 'http://127.0.0.1:8787'}/chat`, {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ model: 'MiniMax-M3.1-Flash', stream: true, max_tokens: 8192, temperature: 0.1,
    messages: [{ role: 'user', content: [
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data: image.toString('base64') } },
      { type: 'text', text: `${prompt}\n\ninternal clicky pointing requirement:\nReturn one V2 target.` },
    ] }] }), signal: AbortSignal.timeout(90000),
});
if (!response.ok) throw Error(`Local proxy HTTP ${response.status}`);
const stream = await response.text();
const text = stream.split('\n').filter(line => line.startsWith('data:'))
  .map(line => JSON.parse(line.slice(5)).delta?.text || '').join('');
const match = text.match(/\[POINT_V2:(\d+),(\d+):[^\]]*:screen1\]/);
if (!match) throw Error('Model did not authorize a point.');
const point = { x: Number(match[1]) * width / 1000, y: Number(match[2]) * height / 1000,
  normalizedX: Number(match[1]), normalizedY: Number(match[2]), width, height };
if (outputFile) writeFileSync(outputFile, JSON.stringify(point, null, 2));
console.log(JSON.stringify(point));
