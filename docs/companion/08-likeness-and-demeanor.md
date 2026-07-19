> 伴灵模式计划 · 模块文档 — [索引与阅读顺序](README.md)
> 章节编号(§0–§8)沿用拆分前的全局编号,跨文件引用见索引的对照表。

## 8. 神似与神态(Likeness & Demeanor)

> 写于 2026-07-19,起因是真实用户反馈:**"抓不太到人物的神态"**,
> 以及本人指认"第三个(Radiant)更符合神态,更拽一点"。
> 本节的所有诊断都来自直接阅读 `mac/pet_generation.swift` 的 prompt 正文。

### 8.1 这与 §4.9/§4.10 的"一致性"是两个正交问题

必须先把这两件事分开,否则会拿错工具解决问题:

| | 一致性 (consistency) | **神似 (likeness / 神态)** |
|---|---|---|
| 问的是 | 帧与帧之间是**同一个角色**吗 | 这个角色读起来**像这个人**吗 |
| 参照物 | 锁定的基准形态图 | **本人的源照片 / 本人的主观判断** |
| 失败表现 | 第 5 帧的角色和第 1 帧不是一个人 | 每一帧都高度一致,但**都不像她** |
| 处理章节 | §4.9、§4.10 | **本节** |

**当前这次反馈正是"一致性满分、神似不及格"** —— 三个阶段高度一致
(服装、发色、比例都对得上),但本人认不出神态。**§4.10 的自动度量
完全不会报警**,因为它测的是格与格之间的偏离,不是与本人的偏离。

### 8.2 根因:prompt 在主动要求"中性"

诊断依据是 prompt 正文,不是推测。

**(a) 三处明确要求 neutral,一处锁死 pose**

- 候选板:`one isolated, front-facing, full-body neutral standing pose with eyes open and feet visible`
- 进化表:`Use the same front-facing neutral standing pose, open eyes, horizontal center, and ground baseline`
- 进化表:`Never change identity, species, pose, outfit, or primary palette`

模型忠实执行了指令。**神态不是丢失了,是被要求删掉了。**

**(b) 防泄漏规则过宽,把神态和背景一起扔了**

候选板里:`Do not copy any source pose, crop, background, screenshot layout, caption, social-app chrome, play control, handheld phone/camera, ...`

`source pose` 和 `background / chrome / caption` 被写在同一条禁令里。
防止抄背景和 UI 是**对的**,但**姿态承载的是身份信息,不是泄漏风险**。
歪头、视线朝向、重心偏移、肩线倾斜 —— 这些正是"像不像本人"的主要载体,
现在被一并禁止。

**(c) `likenessInstruction` 只描述结构,不描述神态**

最高档(≥0.66)的全文是:

> `Preserve facial or marking structure, primary colors, outfit colors, and signature trait very closely.`

**没有一个字提到表情、眼神方向、嘴角、姿态、气质。**
所以"高相似度"目前的定义是"五官结构和配色对",而人认脸靠的远不止这些。

**(d) 6 个 temperament 是"生物系"原型,人形伴灵套不进去**

`CustomPetTemperaments` 的 promptFragment 用的词是
`alert ears or feelers`、`lifted paw or tail`、`small scarf or crest-like signature detail`。
这套词汇是给小动物 familiar 写的。**6 个选项里没有一个能表达"拽"**,
而且把连续的人格空间量化成了 6 个固定档。

**(e) 全身构图 + 140–220px 渲染高度 ⇒ 脸只有 ~20–30px**

`MIMO STYLE` 要求 `tiny full body`、`feet fully visible`、
`readable at 140–220 px tall`。神态主要住在脸上(眼神、眉、嘴角),
而当前构图给脸的像素预算约 20–30px。
**这一条 `docs/diy-strategy.md` 已诊断过(P0:bust 构图),本节确认它同时是神态问题的根因。**

### 8.3 "第三个更像"这条反馈的含义:进化轴与神似轴被耦合了

三阶段的 **pose 被锁成完全相同**,所以阶段间差异只剩比例与细节量:

- SEED:`youngest and smallest; simplest silhouette and fewest details` — **最 chibi**
- RADIANT:`clearest evolved silhouette`,更高、细节最多 — **最成熟**

本人指认 RADIANT 最像,**强烈提示 chibi 化程度与成年人神似度直接冲突**:
越 chibi 越像通用挂件,越不像具体某个人。

**这是产品问题不只是 prompt 问题**,因为:

> **用户第一眼看到的是"初生",而初生恰恰是最不像本人的那一版。**

**待拍板 Q11**:人形伴灵的进化轴要不要与 chibi 轴解耦?
- A(建议):**神似度设下限,三阶段都不得低于该下限**;进化只改
  细节量、silhouette 复杂度、光效,**不再通过"更 chibi"来表达"更年幼"**
- B:人形伴灵的 SEED 直接采用较成熟的比例,只有非人形伴灵走 chibi 进化
- C:维持现状,接受初生阶段神似度较低

### 8.4 神态的三层拆解(决定了各自该用什么手段修)

**这是本节最重要的框架** —— 神态不是单一属性,分三层,**修法完全不同**:

| 层 | 内容 | 手段 | 阶段 |
|---|---|---|---|
| **静态神态** | 五官微表情:眼神方向、眉形、嘴角单侧上扬、下巴角度 | prompt + **bust 构图给足脸部像素** | P3 |
| **姿态神态** | 站姿:重心偏移、歪头、肩线不平、手的习惯位置 | prompt(解除 neutral 禁令)+ 锚点/镜像系统 | P3 |
| **动态神态** | 节奏:idle 快慢、对光标的反应积极程度、驻留时长、走路步频 | **行为包 + 程序化变换层** | **P1** |

**第三层是被严重低估的一层。** "拽"不只是一张图 —— 一个拽的角色
**站姿重心压在一条腿上,而且 idle 更慢更从容、你的光标靠近时它不急着理你、
坐下后驻留更久**。这些全是**行为**,不是美术。

而 Mimo 已经有这个钩子:`CustomPetTemperaments` 里的 `motionID`
现在只是选一个 CSS 动画(`calm-breathe` / `proud-hop` / ...)。
在 §4.3 的架构下,**它应该变成"选一份行为包 + 一组程序化变换参数"**:

```jsonc
// 举例:"拽" 这个 temperament 的动态层
{
  "idleDwellMultiplier": 1.6,        // 驻留更久,不急躁
  "cursorReactivity": 0.3,           // 光标靠近时不太搭理你
  "walkCadence": 0.85,               // 步频略慢
  "postureLean": { "hip": 0.15, "headTilt": -4 },   // 重心与歪头
  "behaviorWeights": { "SitAndFaceMouse": 0.4, "LookAway": 2.0 }
}
```

**推论:神态问题不能只在 P3(生成)解决,P1(行为)承担了第三层。**
这也是 D8 那条"行为层不关心渲染方式"的直接收益 —— 同一套 temperament
既调行为权重又调程序化变换,与角色是生成的还是代码画的无关。

### 8.5 具体改动

#### (1) 拆开"防泄漏"与"取姿态"

把 `source pose` 从禁令里移出来,单独给一条正向指令:

```diff
- Do not copy any source pose, crop, background, screenshot layout, caption, ...
+ Do not copy any source crop, background, screenshot layout, caption, social-app
+ chrome, play control, handheld phone/camera, product tile, text, logo, or watermark.
+
+ CHARACTERISTIC BEARING — extract, do not discard
+ From the identity evidence, extract the subject's habitual bearing and carry it
+ into the familiar's canonical idle stance: head tilt, gaze direction relative to
+ the viewer, weight distribution between the legs, shoulder line, and mouth
+ asymmetry. Bearing is identity, not background. Reproduce the bearing; never
+ reproduce the photograph's framing, props, or setting.
```

#### (2) `neutral standing pose` → `canonical idle stance`

精灵图确实需要一个**规范 idle 姿势**(否则动画接不上),但
**"规范"不等于"中性"**:

```diff
- Each is one isolated, front-facing, full-body neutral standing pose with eyes
- open and feet visible.
+ Each is one isolated, full-body canonical idle stance with eyes open and feet
+ visible, facing the viewer within ±15°. The stance must express the subject's
+ characteristic bearing (§ CHARACTERISTIC BEARING) rather than a neutral A-pose.
+ Asymmetry is expected and desirable: even weight on both feet, a perfectly level
+ shoulder line, and a dead-center forward gaze all read as generic and must be avoided.
```

保留的部分:`feet visible`、安全区约束、`facing the viewer`(锚点与镜像
系统需要正面基准)。删掉的只是 `neutral`。

#### (3) 新增独立的"神态描述"输入槽,与 temperament 分开

现有 `Temperament: \(personalityVisual)` 是**生物系原型**,不适合承载人形神态。
新增一个**独立轴**:

```
BEARING: <structured descriptor>
```

**关键:用物理描述,不用形容词。** 模型对"拽 / sassy / confident"
这类抽象词的响应远不如对具体身体特征的响应:

| 形容词(弱) | 物理描述(强) |
|---|---|
| 拽 / cocky | 下巴微抬、视线偏离镜头、单侧嘴角上扬、重心压在一条腿、肩线不平 |
| 温柔 | 头微低、视线柔和直视、双肩放松下沉、嘴角平缓 |
| 疏离 | 视线越过镜头、下巴收、手臂靠近躯干 |

这个槽应当:
- 由预处理从源照片**自动提取初值**(Vision 已有人脸/姿态能力)
- **允许用户编辑** —— 因为本人是唯一权威(见 8.6)

#### (4) bust / 半身构图(人形伴灵)

沿用 `docs/diy-strategy.md` 的 P0 结论。**这是单点收益最大的改动** ——
静态神态需要脸部像素,而现在只有 ~20–30px。
注意与 §4.6 的 actionSheet 联动:动作帧需要全身,**表情帧可以用 bust**。
两种构图共存,由 artifact 类型决定。

#### (5) 神态候选条:把"她说第三个更拽"变成流程内的一步

**当前这条反馈是在生成完之后才出现的 —— 应该把它提前成一次显式选择。**

复用候选板机制,但**换一根轴**:身份锁定不变,只变 bearing。

```
现有 candidateBoard:  同一身份,三种设计取向(脸/剪影/标志物)
新增 bearingBoard:    同一设计,三种神态(由源照片提取的 3 个变体)
```

用户(或本人)点一下选中最像的那个,选择结果写进 manifest 的
`bearing` 字段,后续所有 artifact 都锁定它。
**成本 +1 次调用,但它解决的是"生成完才发现不像"这个最贵的返工。**

#### (6) 表情参考图单独作为一路参考

预处理现在产出的是身份板(人物检测 + 主体裁剪 + 去背景)。
**追加一张脸部特写裁剪**作为独立参考图:
- OpenAI:作为额外的 `image[]`(上限 16,现在只用了 3–4)
- **Gemini:走类型化的"角色参考"槽** —— 这正是 §4.9 里说的
  它相对 OpenAI 的真实结构性优势,神态是它最该被用上的场景

> ⚠️ **隐私约束不变**:`generation_draft.swift` 现有的
> "从不留存用户源照片"规则**同样适用于神态裁剪与提取出的 bearing 描述**。
> bearing 描述是从照片派生的人物特征,按同等敏感度处理。

### 8.6 怎么验收:神似只能由人判定

§4.10 的 Vision feature print 度量**不能直接搬来测神似**,原因是
**跨风格域**:一端是真人照片,另一端是像素风精灵。
嵌入距离在跨越这么大的风格差时不可靠 —— 它会把"风格不同"读成"不是一个人"。

**所以神似的验收标准是人,不是指标:**

1. **本人测试(黄金标准)**:让被生成的本人在盲选中指认哪一版最像。
   本次"第三个更拽"正是这种数据 —— **这是最有价值的一类反馈,
   应该在产品里被系统性地采集**,而不是靠朋友随口说。
2. **神态候选条的选择率**:如果某一档 bearing 被压倒性选中,
   说明提取的初值偏了,应调整默认提取逻辑。
3. **可自动化的只有"负面信号"**:能检测的是**神态被抹平**这个失败模式 ——
   例如肩线水平度、双腿重心对称度、视线是否恰好正对镜头。
   **三项全都"完美对称"= 高度可疑的通用姿态**,可以自动标记。
   注意这只能证伪("这看起来很通用"),不能证实("这像她")。

**建议指标(自动,只作预警)**:

| 检查项 | 可疑信号 |
|---|---|
| 肩线倾角 | ≈ 0° |
| 双足重心偏移 | ≈ 0 |
| 视线偏离镜头角度 | ≈ 0° |
| 嘴角高度差 | ≈ 0 |

四项同时接近零 → 标记"姿态可能被中性化",提示重掷。

### 8.7 实施位置

- **P1**:动态神态层 —— temperament 从"选一个 CSS 动画"升级为
  "选一份行为权重 + 程序化变换参数"(§8.4)
- **P3a**:prompt 改动 (1)(2)(3),bust 构图,以及 §8.6 的中性化预警指标
- **P3b**:bearingBoard 候选条 (5)、表情参考图 (6)、manifest 增加 `bearing` 字段
- **待拍板 Q11**(§8.3):人形伴灵的进化轴是否与 chibi 轴解耦
