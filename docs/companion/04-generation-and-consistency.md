> 伴灵模式计划 · 模块文档 — [索引与阅读顺序](README.md)
> 章节编号(§0–§8)沿用拆分前的全局编号,跨文件引用见索引的对照表。

### 4.8 生成后端抽象:provider 接口

> 事实核查日期 2026-07-18。本节所有 API 事实均已核实到官方文档,
> 引用见 §4.9 末尾。

**动机**:现在 `pet_generation.swift:1245` 把 `field("model", "gpt-image-2")`
硬编码在 multipart 构造函数里,URL 也硬编码在 `:1238`。换 provider 意味着
改这个函数 —— 但两家的**请求形状根本不同**,不是换个字符串能解决的:

| 维度 | OpenAI `gpt-image-2` | Google Gemini(nano banana 系列) |
|---|---|---|
| 端点 | `POST /v1/images/edits` | `POST /v1beta/interactions` |
| 编码 | `multipart/form-data` | JSON,参考图 base64 内联 |
| 参考图 | 最多 **16** 张,**无类型区分**、无权重旋钮 | 最多 **14** 张,**有类型槽**(角色/物体/风格) |
| 尺寸表达 | 显式 `WxH` 像素,近乎自由(见下) | `aspect_ratio` + `image_size`(`512px`/`1K`/`2K`/`4K`) |
| 透明背景 | **不支持**(gpt-image-2 明确不支持;gpt-image-1 支持) | 无原生 alpha(社区共识,Google 未明确表态) |
| seed | **无** | **无** |
| 流式 | 支持 `partial_images` 0–3 | 本轮未核实 |
| 水印 | 无 | **无条件带 SynthID 水印** |

**两条对现有代码有直接影响的发现**:

1. **`gpt-image-2` 不支持 `background: "transparent"`** —— 这是相对
   gpt-image-1 的**能力回退**。现有代码 `field("background", "opaque")`
   是**正确且必需**的,alpha 由 `character_sheet.swift` 的 matte 抠出来。
   provider 接口必须把"是否原生支持 alpha"建模出来,因为两家都不支持,
   **flat matte + 抠图是所有 provider 的共同必经路径**,不是 OpenAI 特有的 workaround。
2. **`/v1/images/edits` 的默认 model 是 `gpt-image-1.5`,不是 `gpt-image-2`** ——
   所以现有那行显式 `field("model", ...)` 在做实事,重构时**不能丢**。

**接口设计**(seam 放在 `PetGenerationCoordinator` 与 URLRequest 构造之间,
上层的 artifact / prompt / ledger / draft 逻辑全部 provider 无关):

```swift
protocol PetImageProvider {
    var id: String { get }                      // "openai.gpt-image-2" / "google.gemini-3.1-flash-image"
    var capabilities: ProviderCapabilities { get }

    /// 把 provider 无关的请求翻译成具体 HTTP 请求
    func buildRequest(_ req: PetImageRequest) throws -> URLRequest
    /// 把 provider 的响应/SSE 翻译成统一的 PetGenerationOutput
    func decode(_ data: Data, response: URLResponse) throws -> PetGenerationOutput
    func streamEvent(jsonData: Data) -> PetImageStreamEvent?     // 不支持流式则恒返回 nil
}

struct ProviderCapabilities {
    let supportsTransparentBackground: Bool     // 两家目前都是 false
    let supportsStreaming: Bool
    let supportsSeed: Bool                      // 两家目前都是 false —— 见 §4.9
    let maxReferenceImages: Int                 // OpenAI 16 / Gemini 14
    let hasTypedCharacterReference: Bool        // OpenAI false / Gemini true
    let watermarked: Bool                       // OpenAI false / Gemini true(SynthID)
    func validate(size: PixelSize) -> Bool      // 各自的尺寸约束
    func estimatedCost(size: PixelSize, quality: PetGenerationQuality) -> Decimal?
}

/// provider 无关的请求描述 —— 上层只构造这个
struct PetImageRequest {
    let prompt: String
    let references: [ReferenceImage]            // 带 role: .character / .style / .identity
    let size: PixelSize
    let quality: PetGenerationQuality
    let delivery: PetGenerationDelivery
}
```

**关键设计点**:

- **`ReferenceImage` 带 `role`。** OpenAI 侧把 role 丢掉(它没有类型槽),
  Gemini 侧映射到对应的类型槽。**上层永远按语义传参**,provider 负责降级。
  这样"Gemini 的角色参考槽"这个真实优势能被用上,而不是被抹平成
  最小公分母。
- **`supportsSeed` 现在两家都是 false**,但接口里留着 —— 若将来接
  Vertex AI Imagen(**已核实:它确实有确定性 seed,但要求
  `addWatermark: false`**)或本地 SD/ComfyUI,这个能力位就有用了。
- **尺寸不再是两档枚举。** `PixelSize` 是自由的,由
  `capabilities.validate(size:)` 校验。gpt-image-2 的约束是
  长边≤3840 / 边长是16的倍数 / 比例≤3:1 / 总像素∈[655360, 8294400];
  Gemini 是 aspect_ratio + 档位。
- **`generation_ledger.swift` / `generation_draft.swift` 保持 provider 无关** ——
  预留守卫、取消令牌、草稿保留对谁都一样。**这两个组件当初的抽象层次
  是对的,不用动。**
- **成本估算进接口**(`estimatedCost`),因为定价差异大且按尺寸/档位变化,
  UI 要在生成前给用户一个数。

**配置与 A/B**:provider 选择是 settings 里的一个下拉 + 各自的 Keychain 条目
(`MimoSecret` 加一个 case)。**默认仍是 OpenAI**(理由见 §4.9)。
A/B 开关允许对同一只伴灵用两家各跑一次,用 §4.10 的度量打分对比。

### 4.9 provider 对比:跨帧角色一致性

> ⚠️ **这一节推翻了一个流行前提,请先读这段。**
>
> 「nano banana 在跨帧角色一致性上更好」这个说法**未能证实**。
> 它似乎源自 2025 年 Gemini 2.5 Flash Image 刚出时 —— 那时它确实是
> 一次阶跃,Google 也主推这一点。但截至 2026-07 我能核实到的唯一
> 公开盲测榜(arena.ai image-edit,2026-07-10 快照,2817 万票)是:
> **gpt-image-2 以 1465 分居首,领先最好的 Gemini 条目(gemini-3-pro-image-2k,
> 1388)约 77 Elo。**
>
> 但这个榜**测的不是我们要的东西** —— 它是单图编辑的盲选偏好,
> 美观度/指令遵循/审美全部折叠进一票。**我没有找到任何隔离测量
> "跨次生成的角色身份保持"的基准。** 两个方向的证据都不充分。
>
> **结论:不要凭口碑选 provider。用 §4.10 的度量在自己的角色上跑 A/B。**
> 这也正是 §4.8 那个接口存在的首要理由。

#### 已核实的事实对比

| | OpenAI `gpt-image-2` | Google `gemini-3.1-flash-image` / `gemini-3-pro-image` |
|---|---|---|
| **seed / 确定性** | **无** | **无** |
| **角色参考机制** | 16 张无类型参考;**无 fidelity 旋钮**(`input_fidelity` 仅 1.x 可用,gpt-image-2 自动全高保真) | **有专门的角色参考类型槽**;总参考 ≤14 |
| **厂商自述** | 官方 guide **主动承认**:模型"可能偶尔难以在多次生成之间为重复出现的角色或品牌元素保持视觉一致性" | 营销页称"可跨工作流保持至多五个角色的一致性与形似" |
| **盲测榜(image-edit)** | 1465 ± 4(第 1) | 1388 ± 3 / 1385 ± 4 |
| **单图价格(1024²)** | low $0.006 / medium $0.053 / high $0.211 | 3-pro 1K/2K $0.134;3.1-flash 1K $0.067 / 2K $0.101;2.5-flash $0.039 |
| **批量折扣** | Batch 支持 | **Batch 一律半价** |
| **水印** | 无 | **SynthID,无条件** |

**几点解读:**

- **OpenAI 官方文档主动承认这个失败模式**,这是厂商在自家开发者文档里
  承认我们这个 app 正围绕其构建的问题 —— 我给它的权重高于任何营销文案。
  它同时也说明:**这不是选对 provider 就能消除的问题,只能测量+修复。**
- **Gemini 的类型化角色参考槽是真实的架构优势**,不是营销词 —— 它在
  API 文档里有明确的槽位分配。这是 §4.8 接口保留 `role` 的直接原因。
- **gpt-image-2 无 fidelity 旋钮**,所有参考图无条件高保真处理。
  对"锁定角色"这个用途,"永远高保真"大概率正是我们想要的,
  但代价是**没有旋钮在保真度与姿态自由度之间做权衡** —— 生成
  大幅度动作帧(如跳跃、攀爬)时若发现姿态被参考图拖住,这是已知无解项。
- **SynthID 水印对消费级产品是个需要考虑的点**(伴灵是用户资产,
  水印是否可接受需产品判断)。**这是 Q8。**

#### 最大化一致性的策略(按已核实的可行性排序)

1. **单次调用出整张网格**(§4.6)—— 在无 seed 的前提下是唯一的强机制
2. **提高每格分辨率** —— 2048² 而非 1536²;这是最直接的常数改动
3. **锁定角色图作为参考图传入**,Gemini 侧走角色类型槽
4. **flat matte + 抠图**:两家都无原生 alpha,所以这是必经路径而非
   workaround。已核实的一条改进:**饱和绿 matte(`#00FF00`)比现在的
   暖白 `#F1ECE2` 好抠得多** —— 角色高光、眼白、浅色毛发在亮度上与暖白
   重叠,而几乎没有角色像素落在纯绿上。代价是边缘绿色溢出,
   业界做法是 prompt 里要求"主体外围 2–3px 白色描边"来缓解。
   **这是 Q9:是否把 matte 换成绿幕。**
5. ~~固定 seed~~ —— **不可用。两家都没有 seed 参数**(已核实,
   在多个官方页面上由"参数列表中不存在"确认)。任何教你在这两家上
   固定 seed 的指南,要么在讲第三方 wrapper 的合成参数,要么在讲
   Stable Diffusion / ComfyUI。**唯一已核实有确定性 seed 的是
   Vertex AI Imagen**(且要求关水印),但那是另一个模型家族,
   风格适配性未评估。

> **架构上最重要的一句话**:因为确定性不可得,**一致性必须是"生成后
> 验证并修复"的,而不是"事前保证"的**。这把 §4.10 的度量循环从
> "锦上添花"提升为**架构的承重部分**。现有的 `replacement(stage)`
> 单格重掷路径已经是这个形状的一半,补上自动度量就完整了。

**引用**(全部为本轮直接抓取的官方页面):
OpenAI 模型与参数 `developers.openai.com/api/docs/models/gpt-image-2`、
`/api/reference/python/resources/images/methods/edit`、
尺寸与透明度与定价 `/api/docs/guides/image-generation`;
Gemini `ai.google.dev/gemini-api/docs/image-generation`、
`/docs/models/gemini-3-pro-image`、`/docs/pricing`;
盲测榜 `arena.ai/leaderboard/image-edit`(2026-07-10 快照);
Imagen 确定性 seed `docs.cloud.google.com/vertex-ai/generative-ai/docs/image/generate-deterministic-images`。

### 4.10 一致性验收标准:怎么判定一张精灵表"够一致可用"

这是 D2 的头号风险的兜底,也是 §4.9 那句"必须事后验证"的落地。

#### 度量方法:Apple Vision,零依赖

```
VNGenerateImageFeaturePrintRequest → VNFeaturePrintObservation
                                   → computeDistance(_:to:)   // 距离越小越相似
```

**已核实**:`computeDistance` 在 **macOS 10.15+** 可用,语义是
"距离越短越相似"。这对本项目是理想选择 —— app 已经在用 Vision
(`reference_preprocessor.swift` 做人物检测/主体裁剪),**零新增依赖、
零网络、零额外成本**。

**两个必须处理的坑**:

1. **必须显式 pin `request.revision`。** 社区报告 Vision 的底层模型在
   iOS 16→17 之间换过,使先前调好的阈值失效。**若我们硬编码一个阈值
   却不锁 revision,一次系统更新就会静默地重新标定我们的质量闸门。**
   (此项为社区报告,Apple 文档未明说 —— 但风险不对称,锁定是对的。)
2. **Vision 的 feature print 是通用语义描述子**,为相册去重/检索调的,
   **不是身份嵌入**。而我们的失败模式恰恰是"同一物种、不同个体"。
   学术界在这个问题上偏好 **DINO/DINOv2 而非 CLIP**,理由正是 DINO 对
   *同类内不同个体* 的区分更敏感(相关文献还指出:CLIP 相似度高于
   ~0.88 后错误率超过 60%,即**在我们所处的区间里 CLIP 已经不提供信息**)。
   **所以:先用 Vision 验证它是否够敏感;不够则回退到打包一个
   Core ML DINOv2**(仍然端上、仍然无网络,代价是 app 体积)。

#### 度量设计

1. 切格,**每格裁到 alpha/matte 边界** —— 否则背景和留白会主导嵌入
2. 对每一格 + 锁定的**基准形态图**各算一次 feature print
3. **每格对基准图打分,而不是相邻格互相打分** ——
   前者测的是"偏离真相",后者会让整张表一起漂移而不被发现
4. 超阈值的格子走 `replacement` 路径定向重掷
5. **记录所有距离值**。有了分布之后,§4.9 那个 A/B(gpt-image-2 vs
   gemini-3.1-flash-image,跑在我们自己的角色上)就是一个下午的实验,
   用我们自己的数据结束 provider 之争。

#### 验收标准

> **诚实提醒:阈值不能抄。** 本轮调研找到的每一个数字,其作者都明确说明
> 是在自己的数据上拟合的(有人 DINOv2 用 0.82,有人 Vision 用 0.35)。
> **必须自己标定。**

**标定流程(一次性,约半天)**:生成约 100 对帧,人工标注
"同一角色 / 已漂移",拟合阈值。这是唯一能得到可信数字的办法。

**一张 actionSheet 的放行标准(建议初值,标定后替换)**:

| 检查项 | 标准 |
|---|---|
| 空帧检测 | 每格 alpha 覆盖率 ∈ [下限, 上限],沿用现有逻辑 |
| **身份距离** | 每格对基准图的 feature print 距离 ≤ `T_pass`;**没有任何一格超 `T_fail`** |
| 身份距离方差 | 格间距离的标准差 ≤ `T_var`(整表一起漂也要抓) |
| 尺度一致性 | 各格 alpha 包围盒高度的变异系数 ≤ 10%(防止某格角色突然变大变小) |
| 锚点可解 | 每格能解出脚底锚点(alpha 底边中位)——否则动画会跳 |
| 无文字标注 | 检出 caption/箭头(模型爱给"模型表"加标注)则整表重掷 |

**分级处置**:
- 全部通过 → 落盘
- 个别格超 `T_pass` 未超 `T_fail` → **自动定向重掷该格**(最多 N 次),
  仍不过则标记并让用户决定
- 任一格超 `T_fail`,或方差/尺度不过 → **整表重掷**(因为很可能是
  这一次采样整体跑偏,单格补不回来)
- **每一次重掷都要过 `generation_ledger` 的预留守卫** —— 自动重试是
  真金白银,不能无限循环。**重试上限要有硬编码兜底。**

**这套标准同时就是 provider A/B 的评分函数** —— 同一角色、同一 prompt,
两家各跑 K 次,比较通过率与距离分布。

---

