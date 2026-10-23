import assert from 'node:assert/strict';
import { test } from 'node:test';
import sharp from 'sharp';
import { centerOnVisibleControl, explicitControlText } from '../minimax-pointing-precision.mjs';

test('positive button identity excludes the explicitly rejected alternative', () => {
  assert.equal(explicitControlText('指一下 Export CSV 按钮，不是 Export PDF。'), 'Export CSV');
  assert.equal(explicitControlText('Point to Export PDF button, not Export CSV'), 'Export PDF');
  assert.equal(explicitControlText('指一下 Research 文件夹图标'), null);
  assert.equal(explicitControlText('指一下 Studio Notes 窗口左上角红色关闭按钮'), null);
  assert.equal(explicitControlText('指一下左侧 Documents 导航项'), 'Documents');
});

test('pixel refinement centers shifted red controls without fixed coordinates', async () => {
  for (const [centerX, centerY] of [[60, 60], [170, 160], [310, 210]]) {
    const image = await sharp(Buffer.from(`<svg width="400" height="300"><rect width="400" height="300" fill="#f4f4f4"/><circle cx="${centerX}" cy="${centerY}" r="9" fill="#ef665c"/></svg>`)).png().toBuffer();
    const point = await centerOnVisibleControl(image, { x: centerX, y: centerY + 20 }, '红色关闭按钮');
    assert.ok(point);
    assert.ok(Math.abs(point.x - centerX) <= 1 && Math.abs(point.y - centerY) <= 1);
  }
});

test('pixel refinement rejects a uniform background rather than inventing a control', async () => {
  const image = await sharp({ create: { width: 400, height: 300, channels: 3, background: '#6b8099' } }).png().toBuffer();
  assert.equal(await centerOnVisibleControl(image, { x: 200, y: 150 }), null);
});

test('outlined white icon buttons are centered without treating the white page as a button', async () => {
  const image = await sharp(Buffer.from('<svg width="400" height="300"><rect width="400" height="300" fill="white"/><rect x="170" y="130" width="34" height="34" rx="6" fill="white" stroke="#bfc3c8" stroke-width="2"/></svg>')).png().toBuffer();
  const point = await centerOnVisibleControl(image, { x: 193, y: 158 });
  assert.ok(point);
  assert.ok(Math.abs(point.x - 187) <= 1 && Math.abs(point.y - 147) <= 1);
});
