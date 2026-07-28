> 伴灵模式计划 · 会话交接 — [索引](README.md)

# 会话交接(2026-07-28)

给下一个会话看的。**先读这份,再读 [README](README.md)。**

---

## 0. 下一个 session 从这里开始 ← 最新

### P1 Starter Actions 已完成；下一步是真实生成验收

**v0.2 Alpha working baseline + P1 已实现并持续 push 到
`codex/walk-rig-prototype`（Draft PR #2）。**

当前完成：

1. 四套生产契约：`gaze 5 / sleep(rest) 9 / tennis 9 / wall 6`；
2. 每次 provider call 固定一个 coherent 3-frame batch，共 `2/3/3/2` calls；
3. 每个成功 batch 立即落盘；重启显示 interrupted，显式重试从断点继续；
4. Studio 四张卡显示 frames、calls、质量、预计成本、进度、取消与重试；
5. canonical mature frame → chained generation → shared normalize/baseline →
   hard QA → desktop Preview → explicit Accept → manifest install 已全接通；
6. runtime 已接五方向 gaze、睡觉三段、完整正手、单个确定性 tennis ball、
   wall stand/sit；
7. 外部 result-folder import 仍保留，但只在 Advanced。

本轮**没有替用户触发任何付费生成，也没有自动启动 App**。代码与离线测试能证明
编排/安全边界，不能替代真实视觉验收。下一步由用户从
`mac/build/Mimo.app` 打开 Settings，选择一只 DIY 伴灵，逐卡生成并
Preview → Accept。完整步骤见 [12-starter-actions.md](12-starter-actions.md)。

P1 关键 commits：

```text
ea70d87 feat(actions): define the starter motion pack
64d85a6 feat(actions): play the starter motion contracts
fd6cc9b feat(actions): persist starter generation jobs
e22fa01 feat(actions): generate coherent starter families
14fd7be feat(actions): checkpoint paid starter batches
9599097 feat(actions): orchestrate starter generation in Mimo
2808ee7 feat(studio): add starter action cards
ac353ea feat(runtime): animate the starter tennis ball
```

验收通过后的扩展方向：更多 optional action packs、creator template、可分享的
pet package、用户发布/下载渠道；个人参考图与 credential 永不进入 package。

---

## 1. 现在在哪

分支 `codex/walk-rig-prototype`，包含此前 `feat/companion-runtime` 与
`fix/pipeline-audit` 的全部历史；不需要分别 push 旧分支。release baseline 已
push，并已创建面向 `main` 的 Draft PR #2。
`./mac/build.sh` 通过；`./mac/test.sh` 29 个 target 全绿；动作/Modal/Python
离线套件 66 项全绿。这台机器的 macOS Vision 仍会报
Code=9(系统 ANE saliency 模型无法加载),测试只针对这一个系统错误 skip feature-print
三项,尺寸分组/闸门等纯策略断言仍完整运行。

已完成 **P00 / P0 / P1 / P3(代码部分)**。跳过了 P2(多屏漫游),未开始 P4。

```
76edccf fix(companion): stop behavior packs driving stage sheets, and add a gait
223ba34 feat: always draw the mature form, and report what the familiar is doing
dce41fd fix(companion): recover a familiar thrown off the screen
3566ccb feat(generation): add the action sheet retry and spend policy
86cbbf1 feat(generation): add the action sheet artifact and prompt
4cd5bb7 feat(generation): slice action sheets into a shared-scale frame strip
ace2efa feat(generation): measure sheet consistency, thresholds fitted to real data
68b4b64 refactor(generation): put the image backend behind a provider interface
9abfbc1 feat(companion): let behavior packs drive the familiar
e9ae256 feat(companion): add behavior packs and the weighted selector
2e426a4 feat(companion): add a sandboxed expression language for behavior packs
```
(再往前 8 个是文档 commit)

## 2. 眼下正在做的事 ← 从这里继续

### 2026-07-22 新系统(优先于下方历史计划)

- walk 生成改为 **16 个差异明确的关键相位,完整包含左+右两步**;
- 生产输出回到验证过的 **2048²/4×4,16 格各512px**;
- 去掉“为了露两只眼强拉 3/4 视角”的冲突,改固定近侧面;
- 附带 `mac/assets/motion-reference/biped-walk-cycle-16.png` 骨架时间轴,
  只提供关节/落脚/左右腿顺序,不提供第二个角色身份;
- 两个硬锦标是 panel 5 与 panel 13 的 **FEET-TOGETHER PASS**:双脚在髋下并行,
  把“左脚张开→并行→右脚张开→并行”的闭环写死;
- 默认走速 46→88 px/s,Wander 34→72 px/s;110px 为完整两步周期,
  16 帧约 12.8fps,右键验收用 16fps;
- 尺寸闸门改为按“相似姿势组”比较:rest 的站→躺、wall 的倚墙→坐下
  不会被当成缩放漂移,同类姿势内忽大忽小仍会拒绝/重掷。

**新 16-key-pose 方案尚未付费跑。**现有伴灵还在用旧 walk strip。不要自动花钱,
也不要宣称已修好步态。

**动作清单已定稿 → [09-action-inventory.md](09-action-inventory.md)**(2026-07-20 用户拍板)。
三个悬而未决的问题全部有了答案:

1. 签名动作**按气质共享 6 套**(D9)—— 共享设计/prompt/行为包,图仍按每只生成;
2. **Mimo 状态集要做**(D10),另把"音乐律动(戴耳机点头)"放进状态集,
   作为 deepWork 期间"安静但活着"的部分解法;
3. 首验 = **走路 8 帧**,单张 S1(走 8 + 站立呼吸 4),生产打包即验证打包,~$0.05。

新增决策 **D11:道具 v1 内嵌帧内**(球/书/茶杯直接画进帧),独立道具 sprite 推 v2。
这解除了"颠球被道具系统阻塞"—— §4 缺口清单里的道具项降级为 v2。

用户选定的签名方向:小道具戏、睡觉小剧场、音乐律动(+ 要求多想,已在
§9.8 备了点子池)。六套气质签名集的具体动作在 §9.3,**用户尚未逐条确认
六套的具体动作设计** —— 下一步先过一遍 §9.3 再动手。

**接下来顺序(§9.6–9.7)**:
1. ~~零成本代码前置~~ **已完成(2026-07-20)**:`attached` 状态、点击→打断均已实现并测试(见 §4);
2. **首验走路 16 帧(第一次真跑动作表管线)← 下一步,第一笔花销 ~$0.05**。
   2026-07-21:清单升级到顺滑档(~195 帧/只,走 16),生产布局从 3×3@2048²
   (不整除,会切分失败)改为 **4×4@2048² = 16 格 × 512px**,
   pose 表与 prompt 已重写为 16 帧走路循环(3/4 侧面、面向左)。
   注意:侧身帧 vs 正面基准的一致性距离可能需要重标定阈值;
3. 通过后按层批量:通用层 → 状态集 → 当前伴灵气质的签名集。

### 两个设计洞察(别丢)

**过渡帧决定质感。** 站→坐直接切会"啪"一下;真正让它自然的是中间 3–4 帧坐下的过程。行为包已支持链式(`Stand → SitDown → SitIdle`),但过渡帧要单独画。

**同样的帧 + 不同权重 = 不同性格。** "贪玩"= 颠球权重高、链向自己、被打断后很快回去;"沉静"= 同样的帧但权重低、驻留久、被打断后不再继续。**所以签名帧可以做成共享库,不必每只都重新生成。**

### 关于"100+ 帧"的关键重构

用户最初说"要 100 多帧"。我一开始理解成"一个走路循环 100 帧",担心一致性。
**正确的理解是:~10 个动作 × ~10 帧。** 这个切分对一致性友好得多 ——
每个动作自己一张图(内部一次前向传播,一致性最强),而且你不会在同一瞬间
看到两个动作,所以跨图微差不易察觉。**之前"跨调用没有一致性机制"的担忧
在这个切分下大部分消解了。**

## 3. 已建成且能用的东西

| 层 | 文件 | 作用 |
|---|---|---|
| 渲染 | `companion_window.swift` `companion_runtime.swift` | 每显示器一个透明全屏层,CALayer 合成,`NSView.displayLink` 单时钟,per-display HiDPI,**alpha 命中掩码** |
| 精灵 | `companion_sprite.swift` | 切帧、**从美术推导脚底锚点**、烘焙命中掩码、帧语义标记 |
| 物理 | `companion_physics.swift` `companion_geometry.swift` | 闭式解积分器、表面容差判定+扫掠、光标 EMA、拖拽阻尼弹簧、**越界自愈** |
| 表达式 | `companion_expression.swift` | 沙箱表达式语言,`${}`/`#{}` 语义,加载期变量校验 |
| 行为 | `companion_behavior.swift` `companion_director.swift` | 加权瓮+条件门控+链、显式状态机、加载期图校验 |
| 行为包 | `mac/assets/behavior/default.json` | 9 行为 12 动作,**改它不用改 Swift** |
| provider | `pet_provider.swift` | OpenAI/Gemini 双实现、尺寸规则、能力声明 |
| 一致性 | `consistency_metric.swift` | Vision feature print,**阈值已用真实数据标定** |
| 动作表 | `action_sheet.swift` `action_sheet_run.swift` | R×C 切分(共享缩放+基线)、重掷与花费策略 |

## 4. 已知缺口(用户的愿景需要这些)

- **道具**:球/书这类独立小物件不存在,但 **D11 已决定 v1 内嵌帧内**,
  独立道具 sprite(Shimeji `BornTransient` 思路)推 v2 —— 不再阻塞任何 v1 动作。
- ~~贴墙状态~~ **已实现(2026-07-20)**:`attached(SurfaceID)` 状态 + `self.surface`
  / `self.attachedSeconds` 变量。空中撞墙/天花板即试探性贴附,行为包选不出
  attached 行为则当帧脱附(等价旧的滑落)。默认包带 `ClingWall` 演示。
  **贴附结束的写法**:`"next": { "additive": false, "refs": [] }` = 松手。
- ~~点击 → 打断~~ **已实现(2026-07-20)**:行为包顶层 `"reactions": { "click": "Poked" }`。
  点击(非拖拽)先恢复抓取前状态(否则落地会 reset director 抹掉反应),
  再触发反应行为;包没定义或被门控时才回落到旧的"打开气泡"。右键菜单不变。
- **16 关键相位 biped 步态已真跑,第二轮 16 midpoint 也已真跑**;第一轮关键帧
  可用,第二轮 M13–M16 被画布底边截成半身而拒绝,均尚未安装。骨架参考只解决
  双足角色,四足动物需独立 body-plan guide,不能把当前图硬套。
- 24 格真实结果已证明“多帧”不等于“多相位”;新方案靠 16 个差异明确的 phase
  + 骨架 + 人眼验收。不要盲目加“重复就自动重掷”烧钱。
- 尺寸漂移现在会按动作组检出并拒绝,不会对每帧 bbox 盲目强制缩放;
  姿势高度变化与模型缩放漂移不能仅靠全身 bbox 安全区分。
- 贴边收起、victory walk 对原生伴灵不生效(仍操作旧 panel)。
- 坐屏幕边缘的 wall 9–16 帧仍未接独立边缘行为;左右墙倚靠已接。
- 内置像素包仍走旧 WebView 路径(D8:不资产化,但要接行为引擎 —— 未做)。

## 5. 花钱的事

**2026-07-23 Wan2.2-Animate 真实侧身视频 POC：原始 77 帧成功，Mimo preview 导入成功，
但硬 QA 拒绝安装。** 私有 Modal job `mimo-side-walk-v1-p0`，官方 Wan commit
`42bf4cfa…`、模型 revision `cb93a225…`、seed 42、20 steps。第一次 pose 预处理发现
f28/f52 单帧骨架坍塌；新增“只修孤立低置信关节、两侧同关节都可信才线性补”的保守修复，
第二次 25 帧审核 sheet 通过。又发现官方 pose MP4 是 78 packets：Wan 的 77-frame
window 会把它扩成 153 帧；H200 staging 现无损裁成精确 77，pose/face 均逐帧解码验证。
官方固定 `src_ref.png` 在 14B 加载后触发 libpng/zlib 冲突，即便 `/tmp` 中 compression-0
PNG 在加载前可回读；最终用**同路径、无压缩 lossless BMP payload**绕过，像素 SHA 与
远端 CPU 双跑哈希均一致。成功原片：
`artifacts/wan/runs/mimo-side-walk-v1-p0/output/wan-raw.mp4`
（512²、30fps、77f，SHA `32a37a78…`）；24 帧 cycle/contact sheet 在相邻目录。

肉眼：完整左右步态和承重相位明显优于静态 image-sheet，身高/衣服/纹身/手表基本稳定；
中段头发出现橙黄高光漂移，脸被头发遮挡，脚底贴源画布边。确定性 postprocess 成功产出
24×512 RGBA strip，Mimo `ActionGenerationJobStore` 用真实 bundle 导入/持久化/预览全过，
但 fail-closed：alpha area deviation 16.98%（阈值 12%）、f24↔f48 alpha IoU 0.937
（阈值 0.97）、appearance 0.150（阈值 0.05），且全周期触底；没有 authored
cycle distance。因此**当前只能 Settings 预览，绝不能点击接受安装**。实际 loop seam
relative-to-internal gate 通过；不要靠放宽阈值或随手填 README 的 provisional `144`
假装 foot lock。下一轮应先把 ref + pose 整体上移留 ground padding，再做时序 video
matting、接触脚追踪和逐帧/累计位移校准。

本次 Modal list-price 估算：L4 两次 `$0.0133 + $0.0098`；前两次 H200 在采样前失败，
按日志存活时间约 `$0.1721 + $0.1374`；成功 H200 160.047s 为 `$0.2527`
（其中 GPU `$0.2018`）。已知合计约 **`$0.5853`**，另有少量 CPU validation/download/
container overhead，非账单。此 Wan 路线**没有调用 OpenAI API，OpenAI 成本 $0**。

**2026-07-22 walk32-v2 M13–M16 局部修复:技术上合成成功,用户肉眼拒绝,绝不能安装。** 不再重画
M01–M12;新增 2×2 `biped-walk-inbetweens-13-16.png` 和 pass 4C prompt,明确四个 midpoint
与 K13→K14→K15→K16→K01 的映射、完整全身和 96px 空底。成品在
`~/Library/Application Support/Mimo/exports/walk32-v2/`;实际 32 帧预览为当前 Codex
`artifacts/walk-image-experiments/2026-07-22/walk32-v2-preview.gif`。四个修复角色完整且身份稳定,但模型把它们
统一画小(中位高 371px vs 保留帧 462px);本地用一个统一 nearest-neighbour 比例放大、
重落同一脚底基线,再只覆盖 M13–M16。该归一化是显式 opt-in,上限 1.3×,不会掩盖任意
per-frame drift。成功 blocking 调用 usage:image input 4,149、text input 703、image output
1,756,按官方 standard 费率精确计算 **$0.089387**。此前同一修复有一次 streaming 请求
在返回一张 partial 后 HTTP 200 流提前结束,没有 terminal usage;它是否/如何计费只能查
OpenAI Usage Dashboard,不要把 `$0.089387` 误写成两笔请求的账户总额。另一次看似 6 分钟
卡住其实发生在 API 前:runner 重编译后 ad-hoc CDHash 变化,macOS Keychain 等待授权;
该次没有 preflight、也没有发 OpenAI 请求。**用户最终判断准确:这些仍是宽窄不同的
开合腿站姿,没有可信的 contact/down/pass/up 承重链,32 格只是把错误动作采样得更密。**

**2026-07-22 walk32-v1 第二轮 midpoint:拒绝使用,只调用 1 次,计算成本 $0.151009。**
输入沿用 `walk16-v2` 的 16 个 K 帧,另附确定性 `biped-walk-inbetweens-16.png`,
让 gpt-image-2 一次生成 M01…M16,再本地交错为 `K01,M01,…,K16,M16`。实际 usage:
image input 4,273 tokens、text input 1,027、image output 3,723;按 2026-07-22 官方
standard 费率($8/$5/$30 per 1M)分别为 $0.034184 + $0.005135 + $0.111690。
产物在 `~/Library/Application Support/Mimo/exports/walk32-v1/`,动画预览在当前
`artifacts/walk-image-experiments/2026-07-22/walk32-v1-preview.gif`。**M01–M12 身份/镜头/光照很好,
但 M13–M16 从画布底边溢出,只剩腰部以上,所以 32 帧不能安装。** 这次还发现 slicer
曾对 framed sheet 的 bottom contact 特判放行,导致四个半身 sprite 居然可切出;该例外
已删除并加 framed-bottom regression test。之后只要任何格触底即 `subjectClipped`。

**2026-07-22 walk16-v2 生成成功,等用户肉眼验收,尚未安装。** 仅跑 1 次 medium,
确认 request 顺序为角色原图 → `biped-walk-cycle-16.png` → 风格图。产物在
`~/Library/Application Support/Mimo/exports/walk16-v2/`;raw 4×4 和透明 16-frame strip 都成功。
切分后 alpha bbox 高度 436–454px,最大差约 4.1%,大小一致性良好;无地面投影。
Vision 闸门仍因“正面基准 vs 侧面动作”拒绝(worst 24.27),这是已知不可用信号,
不代表肉眼身份漂移。动画预览在
`artifacts/walk-image-experiments/2026-07-22/walk16-v2-preview.gif`。

**2026-07-22 walk24-v1 付费尝试:拒绝使用。** `attempt-1-raw.png` 在
`~/Library/Application Support/Mimo/exports/walk24-v1/`。优点是身份、大小、侧面镜头
相当稳;致命问题是 24 格主要重复同一类宽跨步,没有清楚的双脚并行通过位。
而且 slicer 正确拒绝了该表:`cell 0 subject is cut off at bottom edge`,所以没有 strip,
不能安装。结论:改为 16 个关键相位,把 panel 5/13 的 feet-together pass 设为
硬约束;站立角色缩到格高约 2/3,底部安全带从 48px 加到 96px。

**2026-07-22 零花费诊断:**旧 walk raw sheet 的 16 格不是 16 个连续步态相位,
而是几组几乎相同的宽跨/合腿姿势;问题在生成结果和旧 prompt,不在 slicer。
加上 110/46=2.39s 才播完一条,16 帧只有约 6.7fps,运行时又进一步放大了拖沓。

**2026-07-21 动作表管线首次真跑(walk 16 帧,共花 ~$0.20)。** 结论:

- **管线端到端全通**:生成(medium 2048² 流式)→ 4×4 切分 16 格 → 共享缩放/基线
  → 一致性打分 → 重掷策略在 3 次上限处停下 → 全部尝试已留档。
  产物在 `~/Library/Application Support/Mimo/exports/action-sheet-live-20260721-150846/`。
- **肉眼质量:身份一致性很好**(发型/衣着/纹身/手表 16 格全稳),等用户看 GIF 判断动画顺滑度。
- **闸门对侧身帧失效(实测数据)**:同角色跨视角(3/4 侧身 vs 正面基准)距离
  16.6–25.2(48 格),与"不同角色"标定区间 11.14–28.99 **重叠** ——
  正面基准无法为侧身表把关。阈值 pass 9.0/fail 13.0 仅对同视角比较有效。
- **表内互比也量过了(零成本,用已生成的 3 张)**:同表 to-medoid 距离 6.0–17.2
  (肉眼确认身份一致的表),仍与"不同角色 ≥11.14"重叠。**结论:Vision feature print
  对动作表的身份把关整体不够格**——姿势变化淹没了身份信号。动作表闸门降级为
  "抓大崩"(空格/尺度跳变/极端离群 to-medoid >~20 提示重掷),身份靠人眼;
  当初搁置的 DINOv2 若未来要自动化批量,再重新评估。
- 每次调用 usage:约 7.3k tokens(输入 3.6k / 输出 3.7k),~$0.05/张。
- 剩余预算充足(3–5 元/只)。

**同日晚些时候:B+C 并行完成。**
- **C:走路真帧已上线。** 第三张(用户认可)抽 8 个最异相帧 → `installActionStrip`
  装进当前伴灵。runtime 按移动距离选帧(脚步锁地),真帧激活时关掉程序化 bob/lean。
  精灵加载器改为按"宽÷高"推断帧数,一个加载器通吃 3 帧阶段表和 N 帧动作条。
- **B:注视表已生成($0.15,3 次都被闸门打回但肉眼很好)。** prompt 已参数化为
  `PetActionSheetPlan`(walkCycle / gaze 两个 plan)。正面注视表距离 12.3–18.5,
  仍高于 fail=13 —— 闸门对"跨表全身对比"整体偏严,维持"人眼验收"结论。
- **关键发现:模型分不清左右**(注视表"viewer's right"的格子画成了朝左或朝上),
  但左侧+上下覆盖很好。**解法与走路相同:只画一侧,运行时镜像** —— 下次注视表
  只要 9 方向(上→左→下)+镜像 = 全 16 方向,更便宜且回避左右混淆。
- 注视表的运行时接线(光标角度→帧)是下一个代码步骤,尚未做。

`ActionSheetRunPolicy`:自动重掷上限 3 次 + 独立于配置的硬天花板(已实战验证)。
DEBUG 构建保留全部尝试(本次 3 张全在)。

建议顺序:先设计清单(零成本)→ 补道具和贴墙(零成本)→
**挑一个动作生成一张验证 low 画质够不够**(~$0.05)→ 验证通过再批量。

`ActionSheetRunPolicy`:自动重掷上限 3 次 + 独立于配置的硬天花板。
DEBUG 构建保留全部尝试(用于验证"3 次"这个数字是否合理)。

## 6. 昂贵的教训 —— 别重新踩

**一致性度量的距离尺度是 8–29,不是 0–1。** 我最初凭直觉写 `0.55/0.9`,
那会拒绝掉有史以来生成的每一张图。已标定值:`pass 9.0 / fail 13.0`,
且有测试把它钉在实测尺度上。

**标定时差点测错对象。** 第一次比"进化阶段之间"的距离,结论是 Vision 几乎
无信息量(95.2% 准确率 vs 92.3% 朴素基线),差点据此去打包 CoreML DINOv2。
**但阶段本来就该不同。** 换成同阶段的表情表重测,立刻干净分离:
可容忍 ≤7.90 / 不同角色 ≥11.14。**推论:格子只能与同一阶段的基准比较。**

**两家 provider 都没有 seed。** 所以一致性只能"生成后验证并修复",
不能"事前保证"。这是整个度量循环存在的理由。

**空间约束的文字指令对 gpt-image-2 无效,画出来的框才有效(2026-07-21 晚,花 ~$0.55 学到)。**
"安全边距 24px"、"地线在格底上方 48px"这类文字全部被无视——模型把每行的隐含
地面画在格线上,脚被格线切掉(12/16 格)。有效的是**要求画出可见格框**
("stay inside the box"它真的听),但两个坑接踵而至:① 模型画的是**它自己的网格**
(行高 573/523/490/462,不是 4×512)——所以切分器现在**检测深色框带、沿画出的网格切**,
并按行高归一化,防止不同行的角色大小不一;② **检测必须在任何清理之前**:
画布最外圈就是框,整布去背景会把框当背景采样、整个网格泛洪删光。框表逐格清理,
无框表保持整布清理。全链路已有单元测试钉住。

**CLI harness 等待生成结果必须泵 RunLoop,不能 semaphore。**
coordinator 的 progress/completion 回调派发到主队列;主线程上等 semaphore
= 永远等一个躺在自己队列里的结果。第一次真跑就这样超时浪费了 ~$0.05
(请求已发出,结果进程退出时被丢弃)。`live_generation_loop` 的
`RunLoop.current.run` 写法是对的,`action_sheet_live_run` 已照改。

**gpt-image-2 不支持透明背景**(相对 gpt-image-1 的回退),alpha 靠 matte 抠图。
尺寸规则:长边≤3840、边长16倍数、比例≤3:1、总像素∈[655360, 8294400]。
**最大正方形约 2880²。** `/v1/images/edits` 的默认 model 是 `gpt-image-1.5`,
所以显式指定 model 是必需的。

**"nano banana 一致性更好"未获证实**,唯一可核实的公开榜单反而指向 gpt-image-2
(但测的是通用编辑,不是跨帧身份)。**用自己的角色跑 A/B,别凭口碑。**

**同一个 frameIndex 在三种图里含义不同** —— 基础表=阶段、表情表=表情、
动作表=姿势。混用导致过"出场是最高形态、落地变初生"。已用
`CompanionFrameSemantics` 修复:**只有动作表的帧允许被行为包驱动。**

**deepWork 会门控掉漫游** —— 写代码的人永远看不到自己做的漫游功能,
而桌宠用户里程序员占比很高。**这是个未解决的产品问题。**

## 6.5 工作方式(用户明示的评估标准,长期有效)

用户同时开多个平行 session 做同样的任务,只采纳最好的输出。被淘汰的通病:
过度工程、没被要求的抽象、简单问题复杂化、**默默做大改动不说清楚**。按权重:

1. **先把模糊需求问清/转译成用户真正想要的**,宁可多问一句,别自作聪明做偏;
2. 单位 token 的有效产出(用户看 ccusage);
3. diff 的可维护性(会被另一个模型抽查挑毛病);
4. 惊喜度:发现用户没意识到的问题并解决(例:3×3 不整除、表情表白花钱两张)。

没有差异化空间的步骤,直说并省下 token —— 用户欣赏这种判断。
**每个大改动都要在回复里明确说明改了什么、为什么。**

## 7. 操作须知

**所有 Mimo 相关保留产物必须在仓库内。** Wan 的输入、预处理、原片、PNG、QA、
日志和费用 manifest 统一放 `artifacts/wan/runs/<job-id>/`；历史 image-sheet
预览放 `artifacts/walk-image-experiments/`。`Downloads`、`~/.codex/visualizations`、
`/tmp` 和 `~/Library/Application Support` 都不能再作为 canonical artifact location。
工具内部临时目录可以用，但 turn 结束前必须把保留结果迁回仓库。

**Claude 每次改完自己 build + test。用户只需退出重开:**
```
pkill -f "Mimo.app/Contents/MacOS/Mimo"; sleep 1; open "mac/build/Mimo.app"
```
**`open` 对已在运行的 app 只会拉到前台,不会用新二进制重启。** 踩过。

**`log show` 对这个 ad-hoc 签名的 app 返回 0 行。** 用状态文件:
```
cat ~/Library/Application\ Support/Mimo/companion-status.txt
```
会显示 `Stand [state=grounded mood=focused focus=3m]`。三种"不动"能区分:
`no behavior pack loaded`(真 bug)/ `nothing selectable`(条件全门控掉了)/
`QuietBreathe [mood=deepWork]`(正确地不打扰)。

**当前伴灵存在 UserDefaults 的 `character` 键**(值形如 `custom:UUID`),
**不是** `customPetSpec`(那只用于 prototype)。踩过一整轮。

**伴灵窗口默认在桌面层**(壁纸上、应用窗口下,2026-07-21 用户要求),
`defaults write com.brianzheng.mimo companionAboveWindows -bool true` 可切回置顶。
地板在屏幕真实底边(screen.frame.minY),不是工作区边。

**装动作条带的一次性 CLI 在旧 session 的 scratchpad 里,新 session 没有。**
重建:`swiftc mac/custom_pet.swift mac/character_sheet.swift <main.swift> -framework Cocoa -framework ImageIO`,
main 里调 `CustomPetStore(root: AppSupport/Mimo).installActionStrip(characterID:action:pngData:)`。
重切原始表用 `ActionSheetProcessor.process(pngData:)`(同样方式编译 harness)。
生成新表用 `mac/tests/action_sheet_live_run.swift`(test.sh 编译产物在
`$TMPDIR/mimo-tests/`,用法见文件头,加 `[plan] [maxAttempts]` 参数)。

**逃生阀**:`defaults write com.brianzheng.mimo companionNativeRuntime -bool false`
强制所有伴灵回到 WebView 路径。

**用户偏好:Claude 只 build 不启动 app,由用户自己跑。** 破例过一次(为确诊),
已致歉。

**测试的 `// sources:` 声明在文件第一行**,加新源文件时要同步更新,
否则测试会响亮失败(这是设计如此)。

## 8. 已拍板决策速查

D1 原生 CALayer · D2 N 帧行为包 · D3 窗口地形推后 P4 · D4 两家 provider 都实现
D5 绿幕 matte(**未实施**)· D6 deepWork 安静 · D7 T1 领养后自动生成
D8 代码绘制角色不资产化但接行为引擎(**未实施**)
D9 签名动作按气质共享 6 套 · D10 Mimo 状态集要做 · D11 道具 v1 内嵌帧内(详见 §9)
D12 伴灵住桌面层(应用窗口之下,companionAboveWindows 逃生阀)
D13 动作表**必须带画出的格框**,切分沿检测到的网格配准(文字版空间约束无效,详见 §6)

**新增(本会话)**:去掉视觉进化轴,永远画最成熟形态;XP/等级保留为专注计数,
不再改变长相。生成 prompt 从"三个进化阶段"改为"同一形态的三次独立绘制"
(同样成本,换来冗余而非两个没人看的形态)。

仍待拍板:Q2 窗口交互边界 · Q4 多实例上限 · Q11 已被上一条取代
