> 伴灵模式计划 · §10 — [索引](README.md)

# 10. 高保真 × 强一致动作生成

**状态：方案 v1（2026-07-23；2026-07-28 收束）**。走路在多轮真实实验后
仍未通过肉眼验收，已退出 Starter；本文中的 walk 记录只保留作历史证据。

## 10.0 结论

HatchPet 的一致性不是来自“更神的一句 prompt”，而是来自一套逐步收窄
自由度的生产系统：

```mermaid
flowchart LR
    A["原始参考"] --> B["Canonical Base"]
    B --> C["每个状态整组生成"]
    C --> D["逐 Row 提取与 QA"]
    D --> E["Approved Contact Sheet"]
    E --> F["四个方向锚点"]
    F --> G["Look Row 9"]
    G --> H["Look Row 10"]
    H --> I["共享尺度 / 基线 / 锚点"]
    I --> J["最终 Atlas + 视觉验收"]
```

但它同时主动把画质压到 `192×208` cell，并要求 `simple face`、
`chunky silhouette`、`limited palette`、`flat shading`。所以这次结果
“角色一致但像素较低”是设计取舍，不是 image model 的画质上限。

Mimo 的方案是：

> 保留 `512×512` 高保真 cell；借 HatchPet 的 canonical lock、artifact
> dependency graph、整组生成、共享注册、逐阶段 QA；不用它的低分辨率
> pet-safe 风格上限。

## 10.1 从真实 HatchPet run 学到什么

检查的 run 具备：

- 1 个 base；
- 9 个标准状态 row；
- 1 个四方向 anchor row；
- 2 个连续 gaze row；
- 每个视觉 job 都有明确 `depends_on`、输入图片角色、输出路径；
- 每个标准 row 都挂原始参考、layout guide、canonical base；
- gaze 还挂 approved standard contact sheet、cardinal anchors、上一 row；
- 逐 row extraction/QA、方向 blind QA、continuity、despill、atlas validation；
- **7 个保留的 rejected gaze attempt**。

这最后一点很重要：成品好不代表“一次就好”。一致性来自：

1. 生成前减少自由度；
2. 生成单位保持 coherent；
3. 每一步只接受通过的 artifact；
4. 失败时分类、修正确根因；
5. 不把失败悄悄混进最终图。

## 10.2 Mimo 已经做对的部分

当前 Mimo 并不是从零开始：

- `mac/pet_generation.swift` 已把 approved stage design 作为 absolute
  identity lock；
- 一个 action 一张 sheet，避免逐帧独立调用；
- motion guide 只管骨架节奏，style board 只管 rendering language；
- `mac/action_sheet.swift` 已使用全帧共享 scale 与 baseline；
- 历史 walk asset 仍可按 travelled distance / cycle distance 驱动；
- `mac/consistency_metric.swift` 已有同阶段 identity gate；
- 自动 retry 有硬上限与成本记录；
- behavior pack 已支持每 pose 单独 `hold`，不必被恒定 FPS 绑架。

因此正确方向不是推翻现有管线，而是把它从“一张 16 格完成一切”升级成
HatchPet 式的 artifact graph。

## 10.3 新决策 D12：Hybrid Coherent Family

### 身份与画质

- canonical master 直接使用 Mimo 已批准的最高保真 stage frame；
- 不再生成一个低细节的“动画 base”；
- 动作保持 `512×512` cell；
- prompt 明确要求保持 canonical 的 detail density、抗锯齿、光影、衣料与
  面部构造，禁止 mascot simplification / chunky repixelization；
- 每次视觉生成挂同一组 reference stack：

```text
canonical master
> identity evidence
> accepted action family
> Mimo style board
> motion guide
> layout guide
```

### 生成单位

| 动作类型 | 生成方式 |
|---|---|
| Idle / 呼吸 | 3 帧，一次生成 |
| Sleep | 躺下 3 + 呼吸 3 + 起身 3 |
| Gaze | 顺时针八方向，共 8 帧 |
| 打网球 | 准备 3 + 击球 3 + 恢复 3；球由 runtime 确定性绘制 |
| 墙边站 / 坐 | stand 3 + ledge-sit 3；墙与屏幕边缘由 runtime 提供 |

产品 Starter 只保留 gaze / sleep / tennis / wall，Idle 是扩展工具。每次 image call
只画连续三帧；后一批同时引用
canonical master 与上一批已通过结果，但 canonical 永远具有最高优先级。

### 修复单位

- matte / grid / extraction / scale / baseline / anchor：确定性修；
- 身份 / 五官 / 服装 / anatomy / 渲染画质 / 动作语义：整组三帧重做；
- 单个 pose 弱：整组三帧重做，禁止默默混入一张无关 generation；
- 同根因连续两次：换 frame budget、pose construction 或生成策略，不再只改
  prompt 形容词。

## 10.4 慢动作不是低 FPS

环境动作应慢，走路和网球保持明确能量。

### 默认节奏

| 动作 | 推荐节奏 |
|---|---|
| idle/breathe | 3 帧约 2.1s |
| sleep | 3 帧躺下 + 3 帧慢呼吸 + 3 帧起身 |
| gaze | 8 个方向；按 cursor angle 取帧 |
| tennis | 9 帧约 1.7s |
| wall-standing | 3 帧约 2.2s |

关键规则：

- calm loop 用 per-frame `hold`，endpoint 多停，transition 少停；
- `rest-enter → sleep-loop → rest-rise` 分段，不用一个 FPS 同时控制躺下和
  呼吸；
- gaze 根据 cursor angle 取 direction，必要时对 angle 做短 easing，不循环播。

完整 hold 表见
[`skills/mimo-animate-pet/references/motion-tempo.md`](../../skills/mimo-animate-pet/references/motion-tempo.md)。

## 10.5 新生产流程

1. **Lock**：批准最高保真 canonical master，写 stable identity traits。
2. **Author**：先写动作 phase、loop seam、anchor、tempo、是否需要 midpoint。
3. **Prepare**：运行 `prepare_action_run.py`，生成 artifact graph、prompts、
   layout guide 与 QA contract。
4. **Generate**：只生成当前 ready 的 coherent family；每个 job 挂 manifest
   列出的全部 reference。
5. **Register**：使用 `ActionSheetProcessor` 共享 scale/baseline/anchor。
6. **Measure**：结构、identity、detail density、scale、anchor、motion seam。
7. **Preview**：真实桌面尺寸、authored holds、至少三圈。
8. **Accept**：人工明确接受后才安装；记录模型、prompt、引用、花费与 retries。

桌面显示大小和动作资产尺寸是两层独立控制：资产始终保持 `512×512` cell，
设置中的 `60%–140%` slider 只统一缩放最终渲染高度。它不能参与逐帧注册，
否则用户调大小会掩盖或重新制造角色尺寸漂移。

项目 skill：

```text
skills/mimo-animate-pet/
├── SKILL.md
├── agents/openai.yaml
├── references/
│   ├── identity-and-fidelity.md
│   └── motion-tempo.md
└── scripts/
    ├── prepare_action_run.py
    ├── validate_action_run.py
    └── render_action_preview.py
```

## 10.6 验收标准

### Fidelity

- 任一帧不能比 canonical 更“Q”、更粗像素、更少颜色或更平；
- 五官、发型、衣服、纹身/手表等 asymmetric cues 可辨；
- 1× cell 与真实桌面尺寸都检查。

### Consistency

- shared scale / baseline / anchor；
- 无一帧改头身比、脸型、服装剪裁、光源或 palette；
- side-view identity threshold 需重新标定，不照搬 front-view 的 Vision 数值；
- contact sheet 与 loop preview 都通过。

### Motion

- pose 顺序正确、loop seam 无跳变；
- ambient 不忙，大动作不拖；
- 无 phase reverse 或重复动作阶段；
- preview 使用 authored holds，而不是统一随便设一个 FPS。

## 10.7 推进顺序

1. 用 `#F1ECE2` 暖色 matte 生成 gaze / sleep / tennis / wall；
2. legacy chroma 只做本机 premultiplied RGBA 反混合，不再付费重掷；
3. 每套先桌面 Preview，用户明确 Accept 后才安装；
4. 走路实验保持冻结，除非用户明确重新开启。

每一步只解决一个变量。不要同时换模型、风格、分辨率、帧数和动作设计。
