> 伴灵模式计划 · 模块文档 — [索引与阅读顺序](README.md)
> 章节编号(§0–§8)沿用拆分前的全局编号,跨文件引用见索引的对照表。
>
> **历史路线图**：本文保留早期 P00–P4 设计依据，不再代表当前排期。
> walk、等级/XP、两 provider 和绿幕默认等条目已被后续决定取代；当前状态与
> 下一步以 [STATUS.md](STATUS.md) 为准。

## 5. 实施路线

> 原则:每阶段结束都是可发布状态;手感优先于广度(先让"拎起来会晃、
> 扔出去会飞"发生,行为系统其后)。**阶段顺序已按 D3 调整:窗口地形从
> 原 P2 推后到 P4,多屏漫游提到 P2。**

### P00 — 接缝与安全网(**先做,无用户可见变化**)

> 新增阶段。理由:**交互层目前零测试** —— `main.swift`(1150 行)、
> `product.swift`(2192 行)、`overlay.html`(2558 行)都不在 `test.sh` 的
> 源文件映射表里,唯一被测的交互代码是 `panel_geometry.swift`(28 行)。
> D1 是一次渲染层重写,无网重构是最大的实施风险。

1. 把纯逻辑抽成可测试的独立文件(沿用 `panel_geometry.swift` 那种
   "纯函数 + `precondition` 测试"的既有风格)。
2. `mac/tests/` 新增 `companion_physics_test.swift`、`companion_state_test.swift`
   骨架并登记进 `test.sh` 映射表;针对 CursorTracker 的 EMA、积分器的
   亚像素累加各写一个测试。
3. **把 `test.sh` 的 `test_sources()` 映射表搬进各测试文件的头部注释**
   (`// sources: panel_geometry.swift`),`test.sh` grep 出来。
   否则 P0 会一次性加十几个文件,每个都要改两处。
   > 更正:早前写的是"改成自动发现"。读过 `test.sh` 后确认那条不成立 ——
   > 每个测试是独立 `@main` 可执行文件、需各自的源文件子集,真正的自动发现
   > 要解析 Swift 依赖关系。搬进文件头解决同样的摩擦,成本低一个数量级。
4. 录当前行为基线(截图/录屏)作为回归对照。
- 验收:`build.sh` + `test.sh` 全绿,app 行为无变化。

### P0 — 原生宿主 + 物理手感(先让它"活"起来)【按 D1 重写】

1. **`CompanionLayerWindow`:每显示器一个透明全屏 overlay + CALayer 树 +
   `CVDisplayLink` 单一时钟**;伴灵与 HUD/journal 拆成两个窗口,HUD 吸附
   伴灵位置。删热区轮询,换 **alpha 命中掩码**。
2. `WorldSnapshot` + **三相 tick**(env → tick → apply);环境采样
   (displays/工作区/光标 EMA)+ Fall/Dragged/Thrown 三件套(§4.4 参数)。
   **`SurfaceResolver` 按"表面集合"接口设计**,P0 只填屏幕/工作区四边。
3. 拖拽改造:panel 平移 → **位置刚性锁光标 + `footX` 弹簧驱动姿态**、
   松手抛掷、落地程序化 squash、边缘收起手势保留。
4. **per-display HiDPI**(`contentsScale`);越界自愈:从屏幕边缘浮回。
5. 像素 lane 的 CALayer 渲染路径(网格 → 预渲染 `CGImage` 缓存,
   **不要每帧重建图元**)。
- 验收:任何角色拎起来会晃、扔出去会飞会弹;伴灵可走到任意屏幕位置;
  点击伴灵旁边空白不再被吞;跨 Retina/非 Retina 不糊;deepWork 时伴灵不动。
  **现有 3 帧伴灵在此阶段仍可用**(靠程序化变换动起来)。

### P1 — 行为系统数据化

1. JSON 行为/动作包 + **自研沙箱表达式求值器**(§4.2,`${}`/`#{}` 语义
   保留,加载期变量名校验)+ 加权选择器 + NextBehaviorList;
   `Fall/Dragged/Thrown` 成为 required 行为。
2. **显式状态机**(`grounded/attached/airborne/held`)+ action 前置条件声明 +
   **加载期图校验**(带源码位置的错误报告)。这是 Shimeji 没有的一层 ——
   它靠 `LostGroundException` 当唯一转移机制,创作错误只能在运行期表现为
   "伴灵神秘地从天上下雨"。
3. focus 引擎上移 Swift,`mimo.*` 进条件绑定;现有全部情绪表现改写为
   默认行为包(victoryWalk、idle 变体、萎靡集)。
4. 三 lane 声明 motion tier;`can()` 门控;渲染协议改造。
5. 【§8.4】**temperament 从"选一个 CSS 动画"升级为"选一份行为权重 +
   程序化变换参数"** —— 这是**动态神态层**(idle 快慢、对光标的反应积极度、
   驻留时长、步频、重心/歪头偏移)。神态不只是美术问题,第三层在这里解决。
6. 【D8】内置像素包 / Lane A 抽象伴灵**各挂一份 `behaviors.json`**
   (只有行为、无图集,`kind: "procedural"`),**渲染仍走代码**。
   加载器识别 `behavior-pack` / `procedural` 两种包。
   程序化角色恒为全 motion tier,所以 `can()` 门控实际只对栅格 lane 生效。
- 验收:不改一行 Swift 能通过编辑 JSON 加一个新 idle 行为;故意写错变量名
  会在**加载时**报错并指出位置(而不是静默 false)。

### P2 — 多屏漫游

1. 多屏 `ComplexArea`、相邻屏缝边跳过、`applicationDidChangeScreenParameters`
   全量重采样 + 越界自愈。
2. 漫游总开关 + "仅空闲时漫游"默认策略。【待拍板 §6-Q1】
- 验收:伴灵能走去副屏而不撞隐形墙;拔掉显示器时正常自愈。

### P3 — 资源包升级 + 生成 pipeline 扩展【按 D2 重写】

> 建议**按 P3a / P3b / P3c 顺序做**,因为一致性度量必须先于批量生成上线
> —— 否则我们是在没有质检的情况下花钱。

**P3a — provider 抽象 + 一致性度量(先做,不改产物)**
1. 按 §4.8 拆出 `PetImageProvider` 接口;OpenAI 实现为第一个 provider,
   行为与现在完全一致(**纯重构,产物零变化,现有测试必须继续通过**)。
   `PetImageOutputSize` 从两档枚举改为受 `capabilities.validate` 约束的自由尺寸。
2. 按 §4.10 实现 Vision feature print 度量 + **pin `request.revision`**;
   先只**记录距离不拦截**,跑在现有的进化表/表情表上收集分布。
3. **阈值标定**:约 100 对帧人工标注,拟合 `T_pass`/`T_fail`/`T_var`。
   若 Vision 区分度不足 → 评估打包 Core ML DINOv2。
4. 【§8.5】**神态 prompt 改动**:拆开"防泄漏"与"取姿态"、
   `neutral standing pose` → `canonical idle stance`、新增独立的 BEARING 描述槽
   (物理描述而非形容词)、人形伴灵改 bust 构图。
   同时加 §8.6 的**中性化预警指标**(肩线/重心/视线/嘴角四项同时≈0 则标记)。
5. 【D5】**绿幕 matte A/B**:同一批角色分别用 `#00FF00`(+2–3px 白色描边)
   与现有 `#F1ECE2` 生成,比较抠图后的边缘质量。**重点看浅色/白色角色**
   ——绿色溢出对它们伤害最大。通过则全量切换,暖白保留为 fallback 配置。
- 验收:重构前后产物逐字节一致;度量能对已知漂移的历史样本给出显著更大的
  距离;绿幕 A/B 有明确结论(含浅色角色的边缘对比图)。

**P3b — actionSheet 生成**
6. `actionSheet` artifact(2048×2048,3×3=9 帧)+ prompt + R×C 网格切分泛化;
   §4.10 的验收标准接上闸门与分级重掷(**重试上限硬编码兜底**)。
7. `custom_pet.swift` 升 `schemaVersion: 2`;**旧 manifest 自动迁移器**
   (老资产落 T0,不失效)。
8. **T1 动作集(walk / dragged / fall-land)领养后自动生成,+1 次付费调用**;
   从图集烘焙 `.hitmask`。
9. `settings.html`:生成动作入口 + 帧预览 + 单格/整表重掷 + **生成前成本预估**。

**P3c — provider A/B 与其余 lane**
10. 【D4】接入 Gemini provider(角色参考走**类型槽**,这是它相对 OpenAI 的
   真实优势);两家都保留为可切换选项。用 §4.10 的评分函数在**我们自己的
   角色**上跑 A/B,用数据决定推荐默认值。【§4.9 —— 不要凭口碑决定】
   选择 Gemini 时 UI 明示 SynthID 水印。
11. 像素 lane 手工补 T1 运动帧;程序化抽象 lane(diy-strategy Lane A)
   按渲染协议实现,天生全 tier。

- 验收:走完整 DIY 流程,产出的伴灵会走路、被拖时摆动、落地压扁;
  帧间漂移**被自动指标捕获并定向重掷**;**一次生成失败不会烧掉已付费的结果**;
  A/B 报告能回答"哪家 provider 在我们的角色上更一致"。

### P4 — 窗口地形 + 多实例与社交

> **启动前置**:先实测 `CGWindowListCopyWindowInfo` 取 bounds 的权限成本
> (§4.5 的待核实项)。若需要 Screen Recording 权限,重新评估本阶段。

1. CGWindowList 采样 activeWindow,窗口边界作为 `Surface` **塞进
   `WorldSnapshot` 数组**(物理层与行为层零改动 —— 这是 P0 接口设计的兑现)。
2. 窗口移动 delta 重映射 + 80px 放弃阈值 + 失地 → Fall(走**显式状态转移**,
   不是异常)。攀爬 + 显式转角动作。
3. Manager 化(单 tick 驱动 N 只)、Breed/Transform/SelfDestruct、
   totalCount 限流。【待拍板 §6-Q4】
4. Affordance + ScanMove/Interact 双人握手(两只伴灵互相拜访)。
5. (彩蛋,默认关)ThrowIE 式搬窗口,需 AX 权限。

---
