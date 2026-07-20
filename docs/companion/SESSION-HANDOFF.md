> 伴灵模式计划 · 会话交接 — [索引](README.md)

# 会话交接(2026-07-20)

给下一个会话看的。**先读这份,再读 [README](README.md)。**

---

## 1. 现在在哪

分支 `feat/companion-runtime`,working tree 干净,**未 push**。
21 个测试文件全绿,`./mac/build.sh` + `./mac/test.sh` 通过。

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
2. **首验走路 8 帧(第一次真跑动作表管线)← 下一步,第一笔花销 ~$0.05**;
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
- **动作表从未真跑过**:切分器/prompt/闸门/重掷策略全部写好并测好,
  但**世界上不存在任何一张 9 帧动作表**。磁盘上的 3 帧全是老资产。
- 表情帧在原生层不会切(恒用报上来的那一帧)。
- 贴边收起、victory walk 对原生伴灵不生效(仍操作旧 panel)。
- 墙/天花板碰到只会滑走。
- 内置像素包仍走旧 WebView 路径(D8:不资产化,但要接行为引擎 —— 未做)。

## 5. 花钱的事(等用户拍板)

**一次都没调用过付费 API。** 用户预算 3–5 元/只伴灵。

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

## 7. 操作须知

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

**新增(本会话)**:去掉视觉进化轴,永远画最成熟形态;XP/等级保留为专注计数,
不再改变长相。生成 prompt 从"三个进化阶段"改为"同一形态的三次独立绘制"
(同样成本,换来冗余而非两个没人看的形态)。

仍待拍板:Q2 窗口交互边界 · Q4 多实例上限 · Q11 已被上一条取代
