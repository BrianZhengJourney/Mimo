# 伴灵模式

> **v0.2 Alpha · `main` · 2026-08-31。** Mimo 已从旧 WebView 状态角色升级为原生 CALayer 桌面伴灵；当前事实只看 [STATUS.md](STATUS.md) 与代码。

## 先读这三份

1. [STATUS.md](STATUS.md) — 当前可用能力、质量 baseline、发布门槛、最新版检查方式。
2. [SESSION-HANDOFF.md](SESSION-HANDOFF.md) — 下一次开发会话的短交接。
3. [11-custom-pet-integration.md](11-custom-pet-integration.md) — DIY 从参考图到原子安装的完整边界。

## 当前架构

```text
本地工作事件 ──→ Focus / Journal policy ──→ HUD + companion state

照片 / 手工参考图 ──→ identity board ──→ canonical familiar
                                      └─→ Starter Action jobs
                                           └─→ local QA → preview → accept → install

behavior JSON ──→ director / physics ──→ native CALayer companion
Quick Look HTML ───────────────────────→ transparent HUD panel
```

- 原生伴灵负责渲染、物理、命中和行为；WebView 只承载 HUD / Quick Look。
- 状态条跟随实际可见角色顶部，支持手动关闭与 30 秒自动隐藏；Quick Look 支持刷新、键盘切换和 `Esc`。
- Studio 保留候选、恢复中断 job，并在新动作成功安装前保住旧动作。
- Photos 自动分组只提供候选，不声称身份识别；用户确认前不进入付费生成。

## 不可破坏的边界

1. **不静默花钱**：provider 请求必须来自用户明确点击；中断后显式重试。
2. **不静默安装**：生成资产必须通过本机 QA、桌面预览和用户 Accept。
3. **不丢草稿/旧动作**：失败、取消或替换未完成时，已有可用资产继续保留。
4. **本地优先**：活动历史与默认回看留在本机；可选 AI 只处理确认后的有限元数据。

## 文档地图

| 主题 | 文档 |
|---|---|
| 决策与原则 | [00-overview-and-decisions.md](00-overview-and-decisions.md) |
| Shimeji 研究 | [01-shimeji-research.md](01-shimeji-research.md) |
| 基线读码 | [02-mimo-baseline.md](02-mimo-baseline.md) |
| Runtime / behavior / physics | [03-runtime-architecture.md](03-runtime-architecture.md) |
| Provider 与一致性 | [04-generation-and-consistency.md](04-generation-and-consistency.md) |
| Roadmap / open questions | [05-roadmap.md](05-roadmap.md), [06-open-questions.md](06-open-questions.md) |
| 事实核验与来源 | [07-unverified-and-sources.md](07-unverified-and-sources.md) |
| 神似、动作、生成 | [08-likeness-and-demeanor.md](08-likeness-and-demeanor.md), [09-action-inventory.md](09-action-inventory.md), [10-hybrid-action-generation.md](10-hybrid-action-generation.md) |
| Starter Actions | [12-starter-actions.md](12-starter-actions.md) |

历史实验仍可用于考古，但不得覆盖 STATUS 中的当前产品事实或 release gate。
