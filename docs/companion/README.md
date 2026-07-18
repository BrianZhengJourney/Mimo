# 伴灵模式计划(Companion Mode Plan)

把 Mimo 从"角落里会换表情的状态指示器"升级成一个**有物理手感、有行为系统、
可拖可扔、能被 DIY 生成管线喂养**的桌面伴灵。参照物是 Shimeji / Shimeji-ee。

**状态**:设计阶段,尚未开始实施。最后更新 2026-07-18。

---

## 阅读顺序

| 文件 | 含章节 | 内容 | 谁该读 |
|---|---|---|---|
| [00-overview-and-decisions.md](00-overview-and-decisions.md) | TL;DR, §0 | 摘要 + **全部已拍板架构决策(D1–D7)** | **所有人先读这个** |
| [01-shimeji-research.md](01-shimeji-research.md) | §1 | Shimeji 交互模型源码级拆解:行为系统、物理、环境模型、资源包、以及**哪些不该抄** | 想理解"为什么这样设计" |
| [02-mimo-baseline.md](02-mimo-baseline.md) | §2 | Mimo 现状读码结论 + 瓶颈清单 + 要保住的资产 | 上手改代码前 |
| [03-runtime-architecture.md](03-runtime-architecture.md) | §3, §4.1–4.7 | 设计原则 + 运行时架构:窗口/渲染、引擎分层、行为包格式、物理参数、窗口地形、资源包分级 | 实施 P0–P2、P4 |
| [04-generation-and-consistency.md](04-generation-and-consistency.md) | §4.8–4.10 | **生成后端 provider 接口、跨帧一致性对比、验收标准与度量** | 实施 P3 |
| [05-roadmap.md](05-roadmap.md) | §5 | P00 → P4 分阶段路线与验收标准 | 排期 |
| [06-open-questions.md](06-open-questions.md) | §6 | 已拍板汇总 + 仍待拍板项 | 决策时 |
| [07-unverified-and-sources.md](07-unverified-and-sources.md) | §7, 附录 | **未证实的事实断言清单** + 源码/文献引用 | 引用本文任何事实之前 |

> 拆分前是单个 1138 行的 `docs/companion-mode-plan.md`。章节编号保持全局连续
> (§0–§7),所以文中的 `§4.8`、`§4.10` 这类交叉引用仍然有效 ——
> 用下面的对照表定位到文件。

## 章节 → 文件 对照

| 章节 | 文件 |
|---|---|
| §0 决策记录 | `00-overview-and-decisions.md` |
| §1 Shimeji 交互模型 | `01-shimeji-research.md` |
| §2 Mimo 现状 & 瓶颈 | `02-mimo-baseline.md` |
| §3 设计原则 | `03-runtime-architecture.md` |
| §4.1–4.7 运行时架构 | `03-runtime-architecture.md` |
| §4.8 provider 接口 | `04-generation-and-consistency.md` |
| §4.9 provider 一致性对比 | `04-generation-and-consistency.md` |
| §4.10 一致性验收标准 | `04-generation-and-consistency.md` |
| §5 实施路线 | `05-roadmap.md` |
| §6 待拍板 | `06-open-questions.md` |
| §7 待核实断言 + 附录 | `07-unverified-and-sources.md` |

---

## 已拍板决策速查

| | 决策 | 详见 |
|---|---|---|
| **D1** | 渲染宿主 → **原生 CALayer**(每显示器一个透明全屏层,`CVDisplayLink` 单一时钟);WKWebView 退居 HUD | §0, §4.1–4.2 |
| **D2** | 动画帧 → **扩展生成管线到 N 帧行为包**(一次性批量生成,运行时零成本) | §0, §4.6 |
| **D3** | 窗口感知 → **分阶段**,P1 只做屏幕/工作区边界,窗口攀爬推到 P4 | §0, §4.5 |
| **D4** | **两家 provider(OpenAI / Gemini)都实现**,做正式 A/B 用数据定默认值 | §6, §4.8–4.9 |
| **D5** | matte 换成**饱和绿 `#00FF00`** + 2–3px 白描边,P3a 实测验证 | §6, §4.9 |
| **D6** | 漫游默认 = **岗位为主,deepWork 期间永远安静** | §6, §3 |
| **D7** | T1 动作表**领养后默认自动生成**,明示成本并可关 | §6 |
| — | 自动重掷上限 **3 次**;开发期保留全部 1–3 次尝试用于阈值标定 | §6 |

## 三条最重要的约束(读完就走也要记住这三条)

1. **两家 provider 都没有 seed 参数。** 一致性**只能"生成后验证并修复"**,
   不能"事前保证"。这把一致性度量循环从可选项变成架构承重件。(§4.9)
2. **"nano banana 角色一致性更好"未能证实**,现有唯一可核实的公开榜单
   反而指向 gpt-image-2。但那个榜测的不是跨帧身份保持。
   **用自己的角色跑 A/B,不凭口碑。**(§4.9)
3. **交互层目前零测试。** `main.swift`(1150 行)、`product.swift`(2192 行)、
   `overlay.html`(2558 行)都不在 `test.sh` 的映射表里。
   **P00 补测试接缝是硬前置,不能跳。**(§5)

## 下一步

**P00 — 接缝与安全网**:抽出可测试的纯逻辑、补测试骨架、把 `test.sh`
的手工源文件映射表改成自动发现、录行为基线。**不花钱、不改用户可见行为。**
