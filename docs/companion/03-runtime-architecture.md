> 伴灵模式计划 · 模块文档 — [索引与阅读顺序](README.md)
> 章节编号(§0–§8)沿用拆分前的全局编号,跨文件引用见索引的对照表。

## 4. 目标架构

### 4.1 窗口拆分:伴灵本体脱离 overlay panel【按 D1 修订】

现在的单 panel 同时承载 creature + HUD + journal,导致热区轮询、拖拽搬
整块玻璃、creature 永远钉在 panel 右下。拆成:

- **CompanionLayerWindow**(新,**每个 `NSScreen` 一个**):无边框透明
  panel,**frame = `screen.frame`**(全屏,不是 `visibleFrame` —— 伴灵要能
  走到菜单栏区域)。`level = .statusBar`,`collectionBehavior =
  [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`。contentView 是
  裸 `NSView` + CALayer 树,**所有伴灵在同一层树内合成** —— 不是每只伴灵
  一个 OS 窗口(那是 Shimeji 的已知瓶颈:50 只 = 50 个合成器要管的置顶
  半透明窗口,每帧 resize 重绘)。
- **HUDWindow**(现 panel 瘦身):journal/气泡/状态徽章/资源条,仍是
  WKWebView,吸附在伴灵旁或屏幕角(打开 journal 时固定,免得跟着宠物跑)。
  现有 `panel_geometry.swift` 的恢复逻辑归它 —— 这块已有测试,原样保留。
- 两窗通过 AppDelegate 协调;气泡打开时 HUDWindow 变可点击(现有
  `bubbleOpen` 逻辑平移过来)。

> 注:初稿此处方案是"MascotWindow = 240² 小窗,内容仍是 WKWebView,
> 窗口 frame 即伴灵 bounds"。该方案的命中判定确实天然成立,但它把
> 多实例成本、HiDPI、双时钟同步三个问题都留着了。D1 改为全屏层 + CALayer。

### 4.2 引擎归属:全部在 Swift,原生合成【按 D1 重写】

```
┌────────────────────────────── Swift ──────────────────────────────┐
│ EnvironmentSampler(每帧一次,所有伴灵共享同一份快照)             │
│   displays[](各带自己的 scaleFactor)· workAreas                  │
│   cursor(EMA 平滑 dx/dy)· surfaces[](P1: 屏幕/工作区四边;       │
│                                        P4: 追加窗口边界)          │
│   Mimo 语义层:mood / focus / streak / idle                       │
├───────────────────────────────────────────────────────────────────┤
│ CompanionEngine(CVDisplayLink 驱动,三相 tick)                   │
│   ① env.sample()  ② forEach.tick()(逻辑)  ③ forEach.apply()     │
│   BehaviorSelector(加权轮盘 + 条件 + NextBehaviorList)           │
│   ActionRunner(动词 + 组合子)                                    │
│   StateMachine(grounded/attached/airborne/held,显式转移)        │
│   Physics(Fall 积分/扫掠、Dragged 弹簧、Thrown 初速)             │
│   → anchor, lookRight, frameIndex, 变量表(footX 等)              │
├───────────────────────────────────────────────────────────────────┤
│ CompanionRenderer(CALayer 树)                                    │
│   layer.contents = 图集帧的 CGImage(按 frameIndex 取)            │
│   layer.position = anchor 换算 · layer.transform = 程序化形变     │
│   layer.contentsScale = 所在 display 的 backingScaleFactor        │
│   AlphaHitTester:预烘焙的降采样 alpha 命中掩码                    │
└───────────────────────────────────────────────────────────────────┘
```

- **单一时钟**:`CVDisplayLink`(或 macOS 14+ 的 `NSView.displayLink`)驱动
  逻辑与渲染。直接消灭现状"CSS 编译器 + 60Hz `Timer`"双时钟撕裂。
- **三相 tick 照抄 Shimeji**:环境每帧只采样一次,所有伴灵看到同一个世界;
  逻辑与表现完全分离,一只伴灵的更新不会观察到另一只半提交的位置。
  增删推迟到帧边界。这是多实例一致性的前提。
- **HiDPI**:`layer.contentsScale = screen.backingScaleFactor`,在
  `NSWindow.didChangeBackingProperties` 上更新,**每个显示器独立**。
  伴灵跨屏时切换其 scale。消灭现状"零 DPI 处理 + `preserveAspectRatio="none"`
  拉伸"。
- **命中测试**:从图集帧的 alpha 通道预烘焙一张 1-bit 降采样掩码
  (生成资源包时烘焙进 `.hitmask`),`NSView.hitTest` 里查掩码。
  替换现状 `creatureRect()` 那个 10Hz 轮询的 260×265 魔法矩形
  —— 后者与精灵真实边界完全解耦,`displaySize` 是 150 还是 240 都用同一个框,
  后果是最多 ~100ms 的错误命中状态 + 伴灵周围一圈吞掉下层应用点击的死区。
- **表达式求值器:不用 JavaScriptCore,自己写一个约 300 行的沙箱求值器。**
  初稿建议 JSC(系统自带零依赖),但 Shimeji 的教训正在于此:把配置格式
  焊死在引擎内部对象结构上、每伴灵每属性每帧一次 eval、以及一个不受信
  代码执行面。我们要的是**针对显式、带版本的变量 schema** 的小型语言:
  - 支持:数字/布尔字面量、具名变量点路径、算术、比较、逻辑、三元、
    `random()`/`min`/`max`/`abs`/`floor`
  - **不支持**:方法调用、属性赋值、循环、函数定义
  - 变量 schema(显式枚举,加载期校验拼写):
    `world.cursor.{x,y,dx,dy}`、`world.display.workArea.{top,bottom,left,right}`、
    `self.{anchor.x, anchor.y, lookRight, state, footX, heldSeconds}`、
    `world.companionCount`、**`mimo.{mood, focusMinutes, streakMin, isIdle, level,
    frontmostApp}`(语义层,Shimeji 没有的)**
  - **保留 `${}`(init 求一次并缓存)/ `#{}`(每帧重求)的语义区分。**
    注意 libshijima 把两者当同一件事处理(`scripting/condition.cc:8-13`),
    丢掉了这个优化 —— 别重蹈。这个区分决定了 `duration: "${100+random()*100}"`
    是**一次掷骰**还是每帧抖动。

### 4.3 行为包格式(JSON,机制 1:1 对应 Shimeji)

> 变量命名遵循 §4.2 的沙箱表达式 schema:`world.*` / `self.*` / `mimo.*`,
> 无方法调用(`floor.isOn(anchor)` → `self.state == 'grounded'`),
> `random()` 而非 `Math.random()`。**时长以秒计,速度以 px/秒计。**

```jsonc
// pack/behaviors.json
{ "schemaVersion": 1,
  "behaviors": [
  { "name": "Fall",    "frequency": 0, "required": true },
  { "name": "Dragged", "frequency": 0, "required": true },
  { "name": "Thrown",  "frequency": 0, "required": true },
  { "when": "#{self.state == 'grounded' && mimo.mood != 'deepWork'}",
    "behaviors": [
      { "name": "WalkAlongFloor", "frequency": 100 },
      { "name": "SitDown", "frequency": 200,
        "next": { "add": true, "refs": [
          { "name": "DangleLegs", "frequency": 100 } ] } },
      // 自引用高权重 = 几何驻留分布,免显式定时器
      { "name": "SitAndFaceMouse", "frequency": 0,
        "next": { "add": false, "refs": [
          { "name": "SitAndFaceMouse", "frequency": 100 },
          { "name": "Stand",           "frequency": 1 } ] } }
  ]},
  { "when": "#{mimo.mood == 'deepWork'}",
    "behaviors": [
      { "name": "QuietBreathe", "frequency": 300 },
      { "name": "GlanceAtYou",  "frequency": 20 } ] },
  { "when": "#{mimo.mood == 'poisoned'}",
    "behaviors": [ { "name": "SlumpAndWobble", "frequency": 300 } ] }
]}

// pack/actions.json — 动词: stay/move/animate/sequence/select/embedded
{ "schemaVersion": 1,
  "atlas": { "file": "atlas/base.png", "cell": [512, 512], "cols": 3 },
  "actions": [
  { "name": "WalkAlongFloor", "type": "move",
    "requires": "grounded", "produces": "grounded",     // ← 前置/后置,加载期校验
    "targetX": "${world.display.workArea.left + 64 + random()*(world.display.workArea.width-128)}",
    "animations": [
      { "poses": [ { "frames": "4-9", "hold": 0.16, "velocity": [-40, 0] } ] }
    ]},
  { "name": "Fall", "type": "sequence",
    "requires": "airborne", "produces": "grounded | attached:wall",
    "children": [
      { "ref": "Falling" },
      { "type": "select", "children": [
          { "when": "${self.state == 'grounded'}", "type": "sequence",
            "children": [ { "ref": "Bounce" },
                          { "ref": "Stand", "duration": "${4 + random()*4}" } ] },
          { "ref": "GrabWall", "duration": 4 } ] } ] }
]}
```

动词集(Swift embedded,首批):`fall`、`dragged`、`thrown`、`jump`、
`look`、`offset`,后批:`scanMove`、`interact`、`breed`(P4)。
**每个 lane 附带一份默认行为包**;角色可覆盖。情绪调制不做全局 if,
就用 `mimo.mood` 条件门控 —— 与 Shimeji 的环境门控同构。

**`requires` / `produces` 是 Shimeji 没有的一层**(见 P1 第 2 项):
它让加载器能校验 `next` 图里每条边的前置条件在该点**可能**为真。
Shimeji 靠"伴灵神秘地从天上下雨"在运行期暴露的创作错误,我们在加载
资源包时就报出来,**并指出源码位置**。

**兜底策略**:选不出候选时照抄 Shimeji 的"传送 + 坠落"(它确实健壮、
且成立于世界观内 —— Mimo 改为"从屏幕边缘浮回"),但**同时写一条诊断日志
到 `activity_log.swift`**,记下当时状态、位置、被过滤掉的候选数。
Shimeji 这里是完全静默的,对 DIY 创作者是灾难。

### 4.4 物理参数(起点即 Shimeji 手感)

- Fall:`gravity=2`、`resistX=0.05`、`resistY=0.1`(**指数衰减 `v -= v*r`,
  不是二次阻力** —— 便宜、任意步长都稳定,那种微飘的柔和沉降读作"小而轻的
  生物"而非刚体)、**亚像素累积**、位移细分扫掠。
- **亚像素累加器(`modX`/`modY`)别省。** 位置是整数像素(精灵清晰不糊),
  速度是浮点,小数余量向前结转 —— 这是"清晰"和"慢速平滑漂移"同时成立的
  原因,通常这两者是取舍。
- Dragged:锚点钉光标下方 offset(按伴灵尺寸缩放,240px 伴灵 ≈ 90px);
  **位置零平滑刚性锁光标(响应),脚位弹簧 `k=0.1, damp=0.8` 驱动姿态
  (生动)—— 两者解耦是关键**,绝大多数实现平滑的是位置,结果得到一坨糊。
  `footX` 进变量表供动画选帧/选倾角;挣扎计时 + 光标移动重置 +
  90%/tick 几何续命 → 挣脱。
- Thrown:光标速度泄漏平均 `d=(d+Δ)/2`,直接作 Fall 初速。**这是投掷手感
  最重要的一行** —— EMA 而非原始帧差,让"甩出去"变得宽容(释放前卡一帧也
  照样飞)。Shimeji 源码注释直言用意就是防止光标静止两帧时释放速度为 0。
- 落地弹跳 = 程序化 squash-stretch(CALayer `transform` 的 scale,免美术)。
  资源包可以提供手绘 `bounce` 动作覆盖;没有的话引擎兜底 —— 这样**任何**
  生成出来的伴灵都有落地反馈。

> **单位:秒,不是 tick。** Shimeji 的 `Duration` 以 tick 计,且
> `Pose.apply()` 做的是 `anchor.translate(dx, dy)` —— **每 tick 一次整数
> 像素位移,与经过时间无关,整条 pose 路径没有任何 `v*dt`**。后果是
> **时间步长被烤进了每一个资源包**:不改变所有运动距离就无法提升帧率
> (libshijima 只能用 `subtick_count` 打补丁)。我们的行为包**时长以秒计、
> 速度以 px/秒计**,积分器按真实 `dt` 缩放,创作时间基与渲染帧率彻底解耦。
>
> 顺带一个命名陷阱:`Velocity` 是误称,它是**每帧位移**。另外
> `Mascot.xsd:705-713` 声称 pose velocity 朝右时不翻转,但
> `animation/Pose.java:8` 明确 `isLookRight() ? -dx : dx` —— **以代码为准**,
> 这正是为什么所有走路循环都写 `Velocity="-2,0"` 却能正确向右走。

### 4.5 窗口地形【按 D3 推后到 P4;接口在 P1 就要留好】

> **D3:窗口攀爬推到 P4。** P1 只做屏幕/工作区边界。但下面这条**必须在
> P1 就做对**,否则 P4 会变成重构而不是追加:
>
> **`SurfaceResolver` 的接口从一开始就按"表面集合"设计** ——
> `WorldSnapshot.surfaces: [Surface]`,每个 `Surface` 带 `id`(`.workAreaBottom(displayID)`
> / `.window(windowID, .top)`)、`kind`(floor/wall/ceiling)、线段、以及
> `contains(anchor, tolerance:)`。**不要**写成"屏幕边 + 特判窗口边"。
> 这样 P4 加窗口地形时只是**往数组里塞更多 `Surface`,物理层与行为层零改动**。

- **几何来源:`CGWindowListCopyWindowInfo`。** 取 z-order 最顶、layer==0、
  非全屏、与工作区相交的窗口作 `activeWindow`,每帧刷新并计算 delta ——
  完整复刻 `Area`/`Border` 抽象:窗口顶边=Floor、侧边=Wall、底边=Ceiling,
  优先于屏幕边。(注意这个**反转**:窗口的*底*边对伴灵是天花板,*顶*边是地板。)

  > ⚠️ **待实测核实**:初稿断言窗口 bounds **无需任何权限**(只有窗口标题
  > 需要屏幕录制权限,而我们不需要标题;app 归属用 `kCGWindowOwnerPID`
  > 对回 NSWorkspace)。**这一点尚未在近期 macOS 版本上验证。**
  > 这是 P4 是否值得做的**决定性变量** —— 若实际需要 Screen Recording
  > 权限,那是一个显著的用户摩擦点,会改变整个阶段的性价比。
  > **P4 启动前必须先做这一项实测。**
- 窗口移动重映射 + 80px 放弃阈值 + `LostGround → Fall`,照抄。
- **不搬用户的窗口**(ThrowIE 不做,或作为默认关闭的彩蛋放 P4 之后)——
  需要 AX 权限且与"不打扰"的产品气质冲突。【待拍板 §6-Q2】
- 多屏:沿用 `ComplexArea` 思路,相邻屏缝边跳过,伴灵能走去副屏;
  `applicationDidChangeScreenParameters` 时做一次全量重采样 + 越界自愈。

### 4.6 资源包:三 lane 一协议,动作分级

渲染协议(webview 侧):`mount(pack)`、`setAnimation(name, frame,
lookRight, vars)`、`setProcedural({lean, squash, dangle})`。动画清单按
**能力等级(motion tier)**声明,引擎据此裁剪行为包(声明不了 `walk`
动画的角色自动失去 Move 行为,回退为 hop/glide —— 行为包条件里用
`mascot.can('walk')` 门控):

| Tier | 内容 | 像素 lane | raster lane | 程序化 lane |
|---|---|---|---|---|
| T0 静态+形变 | 现有帧 + 程序化 lean/squash/rotate/bob | 免费(已有) | 免费(已有 3×3 帧) | 免费 |
| **T1 核心手感** | walk 循环、dragged 摆动、fall/land | 手工作画(代码网格,一次性) | **1 张 actionSheet(3×3=9 帧),领养后自动生成,+1 次付费调用** | 不需要(参数化) |
| T2 丰富度 | sit、lie、look、climb | 后补 | 1–2 张 actionSheet,用户显式请求 / 高级档 | 参数化 |
| T3 可选 | 挣扎、被摸(hotspot)、庆祝、双人 interact | 后补 | 按需 | 参数化 |

**【D2】raster lane 的生成策略 —— 核心是"一次调用出整张图集"。**

图像模型在**同一张图内**保持角色一致性,远好于跨多次调用。所以不是
"N 次单帧调用",而是:

```
现状:  evolutionSheet   1536×1024  = 3 形态
        expressionSheet  1536×1024  = 1 形态 × 3 表情
新增:  actionSheet      2048×2048  = 1 形态 × 一个动作的 3×3 = 9 帧
                                     (每次调用内部帧间一致)
```

> **尺寸的依据(已核实)**:`gpt-image-2` 接受近乎任意分辨率,约束是
> 长边 ≤ 3840px、两边都是 16 的倍数、长短边比 ≤ 3:1、总像素在
> [655,360, 8,294,400] 之间。1536×1536 与 2048×2048 都合法。
> **但现有 `PetImageOutputSize` 只有 `1024x1024` / `1536x1024` 两档,
> 这是 gpt-image-1 时代的遗留限制**(见 §4.8 的改动清单)。
> 每格像素数是 contact-sheet 质量的头号约束,2048² 的 3×3 网格给每格
> ~682px,明显优于 1536² 的 ~512px。**这是本计划里性价比最高的一个常数改动。**

这样**一只可用的伴灵 = 现状成本 + 1 次调用**,而不是"成本上升数倍"。
T1 那 9 帧配合程序化变换已经能覆盖约 80% 的 Shimeji 手感。

**帧间身份漂移的缓解措施**(这是 D2 的头号风险,详见 §4.9 / §4.10):

1. **单次调用出整张动作表** —— 最重要的一条。9 帧共享同一次前向、同一条
   采样轨迹、同一个空间上下文,模型画每一格时能直接"看到"其他格。
   **在两家 provider 都不提供 seed 的前提下(见 §4.9),这是唯一可用的
   强一致性机制。**
2. **把已定稿的形态图作为参考图传入** —— 现有代码路径已支持多参考图
   (OpenAI 上限 16 张,Gemini 上限 14 张且**有专门的"角色参考"类型槽**),
   加一张是增量改动
3. **prompt 显式约束**:相同配色、相同比例、相同视角、纯色 matte、单元格网格
4. **自动化一致性度量 + 定向重掷** —— 不是"人工看一眼",是
   `VNGenerateImageFeaturePrintRequest` 逐格打分、超阈值的格子走
   `replacement` 路径重生成。**详见 §4.10。**
5. **`generation_draft.swift` 从锦上添花升为必需路径**:N 帧生成更贵、
   更易部分失败,原始 PNG 必须留存以便重新抠图/重新切格,而不是重新付费

**程序化变换层仍然要做**(D2 的明确记录):skew(由 `footX` 弹簧驱动)、
落地 squash-stretch、转身镜像(锚点按 `width - anchorX` 反射)、走路 bob。
理由:(a) 让 T0-only 的旧伴灵不至于是死的;(b) 让 T1 的 9 帧看起来像 20 帧。

**需要改动的层(诚实清单)**:

| 层 | 改动 |
|---|---|
| `pet_generation.swift` | 拆出 provider 接口(§4.8);新增 `actionSheet(stage:action:)` artifact + prompt;`PetImageOutputSize` 从两档枚举改为受约束的自由尺寸 |
| `character_sheet.swift` | 从"3 格横条"泛化为"R×C 网格切分";新增一致性度量(§4.10) |
| `custom_pet.swift` | manifest 升 `schemaVersion: 2`、`kind: "behavior-pack"`;放宽 `invalidSheetDimensions`("exactly 1536 × 512")校验;旧 manifest 迁移器 |
| `generation_ledger.swift` | **基本不变** —— 这是当初做对了的证据;帧数上去后预留守卫从"锦上添花"变"必需品" |
| `settings.html` | 新增"生成动作"入口 + 帧预览 + 单动作重掷 |

- Pose 元数据进包清单:`{frameIndex, anchor, velocity(px/秒), hold(秒)}`
  —— **velocity 烘焙进帧**是零滑步的关键(运动与美术同步推进,角色永远不会
  相对自己的落脚点滑动 —— 这个耦合消灭了精灵桌宠最常见的"飘"),
  raster 运动 sheet 生成时按提示词约定步幅,清单里标定。
- **向后兼容**:现有 3 帧伴灵是新格式的**退化情形** —— 3 帧图集 + 自动
  合成的最小行为包(只有 idle/呼吸)。`custom_pet.swift` 的迁移器在加载
  缺 `schemaVersion` 的旧 manifest 时自动生成。**已有用户的伴灵不会失效。**
- Hotspot(-ee 式):清单里按动画声明可点区域 + 触发行为(摸头 →
  `Petted` 行为)。P3。

### 4.7 与现有 focus 引擎/HUD 的结合

- `Fam` 的 focus 引擎(1Hz、streak、XP)**原样保留**,但不再直接 set
  CSS 状态;它成为 `mimo.*` 语义绑定的数据源(经 bridge 每秒推给 Swift
  引擎,或反向:focus 引擎整体上移到 Swift —— 建议 P1 时上移)。
- 现有情绪状态映射为行为包的条件域:`focused/deepWork` → 安静集;
  `dizzy/poisoned/ghost` → 萎靡集(走得慢、坐着晃、ghost 飘浮无视重力
  —— `gravity=0` 作为 action 参数覆盖,行为包就能表达);`evolved` →
  celebration 集(victory walk 从硬编码 Swift timer 改写为一条普通
  `Move` 行为,删掉 `victoryWalk()`)。
- 点击伴灵 → journal 气泡、⌥Space、右键菜单:不变(打断规则里点击
  优先级低于拖拽判定,与现状一致)。
- 生成 pipeline 的**现有产物路径(候选板/进化表/表情表/草稿/ledger)不变**;
  P3 按 D2 **追加** `actionSheet` artifact、把 `character_sheet.swift` 的
  切分从"3 格横条"泛化为 R×C 网格、manifest 升 `schemaVersion: 2`。
  **老资产自动落在 T0,不失效**(迁移器合成最小行为包)。
  详见 §4.6 的改动清单 —— 这不是"完全不动",是四层的增量改动,
  其中 `generation_ledger.swift` 基本不用改(当初做对了)。

