# 伴灵模式计划(Companion Mode Plan)

把 Mimo 从"角落里会换表情的状态指示器"升级成一个**有物理手感、有行为系统、
可拖可扔、能被 DIY 生成管线喂养**的桌面伴灵。参照物是 Shimeji / Shimeji-ee。

**状态**：v0.2 Alpha working baseline + P1 Starter Actions 已完成，可直接运行。
四套动作已接入 Studio、断点 job、安全 preview/install 与 runtime；下一步是用户
触发首批真实生成并视觉验收，再扩到更多动作/更多用户。最后更新 2026-07-28。

---

## 阅读顺序

| 文件 | 含章节 | 内容 | 谁该读 |
|---|---|---|---|
| [SESSION-HANDOFF.md](SESSION-HANDOFF.md) | — | **会话交接:当前进度、下一步、已知缺口、踩过的坑** | **新会话先读这个** |
| [00-overview-and-decisions.md](00-overview-and-decisions.md) | TL;DR, §0 | 摘要 + **全部已拍板架构决策(D1–D8)** | **所有人先读这个** |
| [01-shimeji-research.md](01-shimeji-research.md) | §1 | Shimeji 交互模型源码级拆解:行为系统、物理、环境模型、资源包、以及**哪些不该抄** | 想理解"为什么这样设计" |
| [02-mimo-baseline.md](02-mimo-baseline.md) | §2 | Mimo 现状读码结论 + 瓶颈清单 + 要保住的资产 | 上手改代码前 |
| [03-runtime-architecture.md](03-runtime-architecture.md) | §3, §4.1–4.7 | 设计原则 + 运行时架构:窗口/渲染、引擎分层、行为包格式、物理参数、窗口地形、资源包分级 | 实施 P0–P2、P4 |
| [04-generation-and-consistency.md](04-generation-and-consistency.md) | §4.8–4.10 | **生成后端 provider 接口、跨帧一致性对比、验收标准与度量** | 实施 P3 |
| [08-likeness-and-demeanor.md](08-likeness-and-demeanor.md) | §8 | **神似与神态** —— 为什么生成的伴灵"不像本人",prompt 根因与改法。与 §4.9 的一致性**正交** | 实施 P3;人形伴灵相关 |
| [09-action-inventory.md](09-action-inventory.md) | §9 | **动作清单定稿** —— 分层帧预算、六套气质签名集、道具内嵌决策(D9–D11)、打包规则与首验计划 | 生成任何帧之前 |
| [10-hybrid-action-generation.md](10-hybrid-action-generation.md) | §10 | **高保真 × 强一致动作生成** —— HatchPet 实证拆解、D12 hybrid coherent-family、慢节奏与新 skill | 生成或修复动作时 |
| [11-custom-pet-integration.md](11-custom-pet-integration.md) | §11 | **完整 DIY 生成接线** —— canonical master → action family → QA → preview → atomic install | 当前实施入口 |
| [12-starter-actions.md](12-starter-actions.md) | §12 | **P1 实施记录与验收** —— 四卡、调用预算、断点状态机、runtime 与检查清单 | 当前验收入口 |
| [05-roadmap.md](05-roadmap.md) | §5 | P00 → P4 分阶段路线与验收标准 | 排期 |
| [06-open-questions.md](06-open-questions.md) | §6 | 已拍板汇总 + 仍待拍板项 | 决策时 |
| [07-unverified-and-sources.md](07-unverified-and-sources.md) | §7, 附录 | **未证实的事实断言清单** + 源码/文献引用 | 引用本文任何事实之前 |

> 拆分前是单个 1138 行的 `docs/companion-mode-plan.md`。章节编号保持全局连续
> (§0–§8),所以文中的 `§4.8`、`§4.10` 这类交叉引用仍然有效 ——
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
| §8 神似与神态 | `08-likeness-and-demeanor.md` |
| §9 动作清单 | `09-action-inventory.md` |
| §10 高保真 × 强一致动作生成 | `10-hybrid-action-generation.md` |
| §11 完整 custom pet generation | `11-custom-pet-integration.md` |
| §12 Starter Actions 实施与验收 | `12-starter-actions.md` |

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
| **D7-R1** | 动作卡领养后自动建立，但**只有用户逐卡点击才会生成**；先显示 calls 与成本 | §11–§12 |
| **D8** | 代码绘制的角色(内置像素包 / Lane A 抽象伴灵)**不资产化**,渲染保持程序化,但**接入同一套行为引擎** | §6 |
| — | 自动重掷上限 **3 次**;开发期保留全部 1–3 次尝试用于阈值标定 | §6 |
| **D9** | 签名动作**按气质共享 6 套**(设计/prompt/行为包共享,图仍按每只生成) | §9 |
| **D10** | **Mimo 状态集要做**(得意/萎靡/困倦/深工 + 音乐律动) | §9 |
| **D11-R1** | Tennis 不在图中画球；runtime 只合成一个确定性球。其他道具逐动作决定 | §9, §12 |
| **D12** | 动作采用 **512px high-fidelity canonical master + coherent family artifact graph**；ambient 以 authored hold 放慢，locomotion 按距离驱动 | §10 |
| ~~Q11~~ | 已被取代:去掉视觉进化轴,永远画最成熟形态(2026-07-20) | §8.3, handoff §8 |

## 三条最重要的约束(读完就走也要记住这三条)

1. **两家 provider 都没有 seed 参数。** 一致性**只能"生成后验证并修复"**,
   不能"事前保证"。这把一致性度量循环从可选项变成架构承重件。(§4.9)
2. **"nano banana 角色一致性更好"未能证实**,现有唯一可核实的公开榜单
   反而指向 gpt-image-2。但那个榜测的不是跨帧身份保持。
   **用自己的角色跑 A/B,不凭口碑。**(§4.9)
3. **外部生成结果不能自行安装。** 所有动作先进入持久化 job store，
   通过 hard QA，并由用户在桌面预览后显式接受；失败结果保留用于诊断，
   不覆盖已安装资产。(§10–§11)

## 下一步

先按 [§12](12-starter-actions.md) 在 App 内生成并验收一只真实 DIY 伴灵的
gaze / sleep / tennis / wall。通过后再做 P2 扩展：更多动作包、创作者模板、
可分享但不含个人原图/credential 的 pet package，以及用户级发布渠道。
