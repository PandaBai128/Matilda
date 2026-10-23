import sharp from 'sharp';
import { spawn } from 'node:child_process';
import { mkdir, stat } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

let helperPromise;
function runProcess(executable, argumentsList, input, signal) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, argumentsList, { signal, stdio: ['pipe', 'pipe', 'pipe'] });
    const chunks = [];
    child.stdout.on('data', chunk => chunks.push(chunk));
    child.stderr.resume();
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve(Buffer.concat(chunks).toString()) : reject(Error('Local target OCR failed.')));
    child.stdin.on('error', () => {});
    child.stdin.end(input);
  });
}
async function ocrHelper() {
  if (!helperPromise) helperPromise = (async () => {
    const source = fileURLToPath(new URL('./vision-target-anchors.swift', import.meta.url));
    const folder = join(tmpdir(), 'matilda-vision-target-helper');
    await mkdir(folder, { recursive: true, mode: 0o700 });
    const binary = join(folder, 'target-ocr');
    const compiled = await stat(binary).catch(() => null);
    if (!compiled || compiled.mtimeMs < (await stat(source)).mtimeMs) {
      await runProcess('/usr/bin/swiftc', ['-module-cache-path', join(folder, 'module-cache'), source, '-o', binary], '', AbortSignal.timeout(30000));
    }
    return binary;
  })().catch(error => { helperPromise = undefined; throw error; });
  return helperPromise;
}

export function explicitControlText(prompt) {
  if (!/按钮|菜单项|导航项|选项|button|control|menu item/i.test(prompt)) return null;
  const positive = prompt.split(/不是|不要|而非|别点|\bnot\b|rather than|instead of/i)[0]
    .replace(/^(?:please\s+)?(?:point(?:\s+me)?\s+(?:to|at)|click(?:\s+on)?|locate|find|show(?:\s+me)?)\s+(?:the\s+)?/i, '')
    .replace(/\s+(?:button|control|menu item)\b.*$/i, '');
  if (/按钮|菜单项|导航项|选项/.test(positive)) {
    return positive.match(/([A-Za-z][A-Za-z0-9_.-]*(?:\s+[A-Za-z0-9_.-]+)*)\s*(?:按钮|菜单项|导航项|选项)/)?.[1]?.trim() || null;
  }
  const names = positive.match(/[A-Za-z][A-Za-z0-9_.-]*(?:\s+[A-Za-z0-9_.-]+)*/g) || [];
  const name = names.at(-1)?.trim() || null;
  return name && !/^(?:(?:red|yellow|green|blue|close|minimize|maximize)\s*)+$/i.test(name) ? name : null;
}

// Pixel refinement has no test coordinates, label-to-position tables or DOM.
// It centers on one compact, closed fill region near the model/OCR anchor.
export async function centerOnVisibleControl(imageBytes, anchor, prompt = '') {
  const source = sharp(imageBytes);
  const { width, height } = await source.metadata();
  const cropWidth = Math.min(width, 512), cropHeight = Math.min(height, 256);
  const left = Math.max(0, Math.min(width - cropWidth, Math.round(anchor.x - cropWidth / 2)));
  const top = Math.max(0, Math.min(height - cropHeight, Math.round(anchor.y - cropHeight / 2)));
  const { data, info } = await source.extract({ left, top, width: cropWidth, height: cropHeight }).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const visited = new Uint8Array(cropWidth * cropHeight), candidates = [];
  const wantedRed = /红色|\bred\b/i.test(prompt);
  function eligible(offset) {
    const red = data[offset], green = data[offset + 1], blue = data[offset + 2];
    const maximum = Math.max(red, green, blue), minimum = Math.min(red, green, blue);
    return maximum > 70 && (minimum > 245 || maximum - minimum > 35 || (maximum < 175 && minimum > 45));
  }
  for (let start = 0; start < visited.length; start++) {
    if (visited[start] || !eligible(start * info.channels)) continue;
    const seed = start * info.channels;
    const seedColor = [data[seed], data[seed + 1], data[seed + 2]];
    const whiteFill = Math.min(...seedColor) > 245;
    const queue = [start]; visited[start] = 1;
    let minX = cropWidth, maxX = 0, minY = cropHeight, maxY = 0;
    for (let cursor = 0; cursor < queue.length; cursor++) {
      const pixel = queue[cursor], x = pixel % cropWidth, y = Math.floor(pixel / cropWidth);
      minX = Math.min(minX, x); maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
      for (const next of [x > 0 ? pixel - 1 : -1, x + 1 < cropWidth ? pixel + 1 : -1,
        y > 0 ? pixel - cropWidth : -1, y + 1 < cropHeight ? pixel + cropWidth : -1]) {
        if (next < 0 || visited[next]) continue;
        const offset = next * info.channels;
        if (Math.max(...seedColor.map((value, channel) => Math.abs(value - data[offset + channel]))) <= (whiteFill ? 6 : 22)) {
          visited[next] = 1; queue.push(next);
        }
      }
    }
    const boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1;
    if (minX === 0 || minY === 0 || maxX === cropWidth - 1 || maxY === cropHeight - 1
        || boxWidth < (whiteFill ? 13 : 8) || boxHeight < (whiteFill ? 13 : 8) || boxWidth > width * 0.25 || boxHeight > height * 0.12
        || boxWidth / boxHeight > 15 || queue.length < Math.max(40, boxWidth * boxHeight * 0.45)) continue;
    if (wantedRed && !(seedColor[0] > seedColor[1] * 1.25 && seedColor[0] > seedColor[2] * 1.25)) continue;
    const center = { x: left + (minX + maxX + 1) / 2, y: top + (minY + maxY + 1) / 2 };
    const distance = Math.hypot(center.x - anchor.x, center.y - anchor.y);
    if (distance <= Math.max(32, width * 0.025)) candidates.push({ ...center, distance });
  }
  candidates.sort((first, second) => first.distance - second.distance);
  return candidates[0] || null;
}

export async function refineComputerPoint({ image, prompt, tag, signal }) {
  const match = tag.match(/^\[POINT_V2:(\d+),(\d+):[^\]]*:screen(\d+)\]$/);
  if (!match) return tag;
  const imageBytes = Buffer.from(image.source.data, 'base64');
  const { width, height } = await sharp(imageBytes).metadata();
  let anchor = { x: Number(match[1]) / 1000 * width, y: Number(match[2]) / 1000 * height };
  const targetText = explicitControlText(prompt);
  if (targetText) {
    const binary = await ocrHelper();
    const boxes = JSON.parse(await runProcess(binary, [], JSON.stringify({ image: image.source.data, target: targetText }), signal));
    const anchors = boxes.map(box => ({ x: (box.left + box.right) / 2 * width, y: (box.top + box.bottom) / 2 * height }))
      .map(point => ({ ...point, distance: Math.hypot(point.x - anchor.x, point.y - anchor.y) }))
      .filter(point => point.distance < Math.min(width, height) * 0.2).sort((first, second) => first.distance - second.distance);
    if (!anchors.length) return '[POINT_V2:none]';
    anchor = anchors[0];
  }
  const centered = await centerOnVisibleControl(imageBytes, anchor, prompt);
  if (!centered && !targetText) return '[POINT_V2:none]';
  const point = centered || anchor;
  return `[POINT_V2:${Math.round(point.x / width * 1000)},${Math.round(point.y / height * 1000)}:目标:screen${match[3]}]`;
}
