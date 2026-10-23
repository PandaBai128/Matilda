# 壮壮动态形象素材

## 方向与边界

依据用户提供的两张壮壮照片：成年小体玩具泰迪，红杏色毛、细巧脸、自然垂耳、浅色下巴、纤细身体和腿。性格安静、聪明、亲近用户。默认头像，可选小身体。2026-10-23 用户追加要求把软件头像统一成新头像：应用图标、菜单栏和面板复用头像图集第一格，菜单栏布局/尺寸不变。原有独立头像素材保留。

动作来自本地鼠标、语音和操作状态，不调用模型、不增加截图。头像先转向鼠标关注的位置，再随原 Medium/Slow 响应跟随；停止时渐停。监听与处理期间停靠，执行后轻点头并在实际落点显示一次短脉冲。指向气泡按用户最新偏好默认“汪，汪汪”，也可选实际目标名称、自定义或隐藏；仅视觉展示，不加入语音或提示词。反馈只代表已派发输入，不表示业务完成。减少动态效果时禁用装饰转动、步态、眨眼及飞行弧线。

## 当前素材

- `leanring-buddy/Assets.xcassets/ZhuangzhuangHeadAtlas.imageset/head-atlas.png`：3 列 × 2 行；中性、左看、右看、侧耳听、闭眼、低头。
- `leanring-buddy/Assets.xcassets/ZhuangzhuangBodyAtlas.imageset/body-atlas-slim.png`：2 列 × 2 行；坐姿、迈步 A、迈步 B、趴姿。身体约为头像占位的 1.65 倍；不会改变菜单栏宽度。
- 每个格子在 SwiftUI 中按纹理裁切，禁止裁切偏移继承动画，防止串格。原始参考照片不打包进 App。
- 应用图标通过 `tools/export-companion-icon.swift` 从已有中性姿态机械导出标准尺寸，搭配代码绘制的浅色圆角底；没有重新生成另一张脸。菜单栏和面板直接渲染同一图集第一格。

眨眼初次 2.4 秒、之后间隔 8.5 秒、闭眼 0.22 秒；鼠标移动只影响休息姿态，不重置眨眼计时。外观设置六个姿态可直接保持预览，小身体选择不会被表情预览改写；“日常”恢复自然动态。

2026-10-23 外观整理后的验证：Xcode UI `10-26-55` 结果 103 项通过、0 失败、1 项原生鼠标 opt-in 跳过。真实 NSHostingView 渲染时序测试验证日常头像自动闭眼后恢复原帧（本机 Reduce Motion 为 false）；六种静态预览与气泡四种模式另经正式安装 UI 检查。未把桌面采样当作持续帧率验收，也未重新验收语音或业务操作。

使用内置 image generation，`transparent_background=true`。下列为实际生成提示词；小身体先生成初版，再做一次收细比例的编辑。生成图保存在 Codex 生成目录，同时将最终引用版本复制进项目资源目录。

## 头像提示词

Use case: stylized-concept. Create ONE production sprite atlas for a tiny macOS companion: the SAME real adult toy poodle Zhuangzhuang in reference photos 1 and 2. Image 3 is a rendering-style reference only, do not copy its chubby generic puppy proportions. The real dog is petite, reddish apricot, with a slender face, small black lively eyes, soft naturally hanging ears, a slightly untidy top tuft, brown-black nose and light cream chin. Render softly realistic detailed fur, readable at 30px, gentle observant expression, closed mouth, no collar or accessories. Exact atlas: 3 columns and 2 rows, six equally sized square cells in a 1536x1024 transparent PNG. Each cell contains only the isolated HEAD, same scale, centered at the exact cell center, same consistent framing and head silhouette size (80% of cell width), 10% clear margin, no neck/body, no labels/grid/borders/text/shadow/background. Row 1 cells: neutral front-facing; gaze and face turned subtly 10 degrees toward viewer left; gaze and face turned subtly 10 degrees toward viewer right. Row 2 cells: attentive listening with subtle 8 degree head tilt; neutral front-facing with eyes gently fully closed for a blink; neutral front-facing with a tiny chin-down nod. Keep same individual identity and head proportions in all cells. Not cartoon, not plush, not big Disney eyes, not a fat round face. Alpha background completely transparent.

## 小身体初版提示词

Use case: stylized-concept. One production transparent sprite atlas for the SAME real small adult toy poodle Zhuangzhuang shown in both reference photos. 2 columns by 2 rows, four equal square cells, 1536x1536. Soft realistic detailed fur rendered as a clean desktop companion cutout, warm reddish-apricot color, dark bright eyes, slender face, slightly untidy top tuft, short hanging ears and pale cream chin. VERY petite, slim narrow torso, thin delicate legs, small paws, the real dog is only about 2kg. NOT a chubby plush puppy, NOT oversized cartoon eyes. Full body entirely visible in every cell. Row1 left: sitting upright quietly, facing the viewer with closed mouth and an attentive slight head tilt. Row1 right: standing in a subtle three-quarter view toward viewer right, one front paw slightly forward. Row2 left: identical standing orientation with the opposite front paw slightly forward, second walking step. Row2 right: lying quietly with slim front legs stretched ahead and head raised looking at the viewer. Same size dog and face across cells, central alignment at 50% cell width and consistent paw baseline at 90% cell height. Sitting and standing head top at 10% cell height. Each whole dog fits inside its cell with transparent margin; no overlaps, no background, no floor, no drop shadow, no collar, no accessories, no labels, no grid, no text. True transparent alpha.

## 小身体收细编辑提示词

Edit target image 1, a 2x2 four-pose transparent sprite atlas. Photos 2 and 3 show the SAME actual adult tiny toy poodle to match faithfully. Change only the dog's proportions and grooming in all 4 cells: he is very small and SLIM, only around 2kg, with a narrow delicate ribcage and lean neck, long pencil-thin lower legs and petite narrow paws. The current atlas is too plush, round, fluffy and puppy-like. Make torso and limbs visibly slimmer, head about 20 percent smaller in relation to body, ears shorter and less poofy, top tuft slightly untidy rather than a spherical fluffy haircut. Keep real natural adult poodle proportions and those alert sweet dark eyes, reddish-apricot coat, pale cream chin, fine fur detail. Not emaciated, no ribs showing, just petite and slender like the photos. Preserve 2 columns x 2 rows layout with exact equal-square cells, pose order (sitting, walking step A, walking step B, lying), the same warm softly realistic style and camera angles, 8 percent transparent margin in each cell, no overlap. Walking step B MUST have the opposite front paw forward from step A. Background must stay fully transparent, no matte, no floor shadows, no text or grid.

## 验证状态

2026-10-23 已完成本次构建与安装验收：

- 全 App Swift 类型检查（macOS 14.2 target，Swift 5）通过；未修改既有非阻塞警告。
- Xcode UI 最终结果 `Test-leanring-buddy-2026.10.23_04-53-48-+0800.xcresult`：99 项通过、0 失败、1 项原生鼠标 opt-in 按设计跳过。随后普通 Build Succeeded，未安装测试宿主。
- 头像图集 1536×1024、小身体图集 1254×1254 的透明区域、逐格裁切与实际 SwiftUI 渲染已检查。测试目标输出的 [头像姿态](verification/companion-motion-2026-10-23/head-poses.png)、[身体姿态](verification/companion-motion-2026-10-23/body-poses.png) 和 [实际尺寸深浅背景](verification/companion-motion-2026-10-23/actual-size-light-dark.png) 已保留。小身体注册仅对齐素材脚底，不修改目标坐标。
- 正式安装 `/Users/nathan/Applications/Matilda.app` 已启动，Apple Development designated requirement 与更新前一致，深度严格签名检查通过；Spotlight、Launch Services 和进程都只指向这一份安装。旧版本可从 `/private/tmp/matilda-motion-final.H6FaiN/previous.bundle` 恢复。
- 安装后通过真实 Appearance 窗口检查头像/小身体切换、聆听、思考和指向标签；切回用户原来的头像、Medium 大小/距离/跟随，保留 5 秒自动隐藏、原泛光及 Screen Control 开启状态。应用激活时的 Matilda 菜单也可直接打开 Appearance；没有新增产品内测试板。
- 本轮没有重新运行 MiniMax 定位、真实麦克风或业务页面点击；操作反馈的派发时机、旧响应隔离和取消由回归测试及调用路径核查验证。没有测量持续实际帧率，也未做真实第二屏运动验收；60fps 是短时飞行时钟目标，不是所有设备的实测保证。减少动态效果分支经过源码检查，但未更改用户系统偏好进行实机切换。
