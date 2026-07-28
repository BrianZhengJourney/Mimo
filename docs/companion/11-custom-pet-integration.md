> 伴灵模式计划 · §11 — [索引](README.md)

# 11. 完整 Custom Pet Generation

**状态：P1.1 Starter Actions 已实现（2026-07-28）；等待用户在 App 内做最终桌面视觉验收。**

目标不是再做一条独立生成 demo，而是把已经验证过的 canonical character、
action production、hard QA、preview 与 manifest 安装接成一个用户可恢复的
Mimo Studio 流程。

## 11.0 当前接缝

已经接通：

- `reference_preprocessor.swift`：在本机整理与确认身份证据；
- `PetGenerationCoordinator`：生成 canonical master / expression assets；
- `StarterActionCatalog`：五套生产动作、三帧 coherent batches、最终帧数与 timing；
- `StarterActionJobStore`：独立 job、调用记录、取消、重试上限与 batch 断点；
- `PetGenerationCoordinator`：从已采用角色的 mature canonical 逐 batch 生成；
- `ActionSheetProcessor`：跨 batch 一次性共享 scale / baseline / anchor；
- `ActionGenerationJobStore`：持久化、hard QA、desktop preview、显式接受；
- `CustomPetStore` manifest v4：按动作名原子安装 strip 与播放元数据；
- `CompanionRuntime`：八方向 gaze、分段 sleep、tennis runtime ball、wall stand/sit、distance walk；
- Settings：五张 durable action cards，显示 frames / calls / cost / progress / retry / 本机重新抠图。

仍待真实用户验收：

- 用户在自己的 API 账户上逐张点击生成五套视觉资产；
- 逐条检查 identity、动作语义、循环 seam，再 Preview → Accept；
- 基于首批真实结果调整 prompt/视觉 QA，但不能静默重掷或放宽安装边界。

## 11.1 目标流程

```text
reference images
      ↓
local identity board + explicit confirmation
      ↓
high-fidelity canonical master
      ↓
temperament + body-plan action plan
      ↓
action-family jobs (independent, resumable)
      ↓
deterministic normalize / register / alpha / motion QA
      ↓
desktop preview + explicit user acceptance
      ↓
atomic manifest v4 install
      ↓
behavior pack drives the native companion
```

每个 action family 是独立 artifact。某个动作失败时，用户仍可使用 canonical
master 与已经通过的动作；不得因为一格或一条失败而重做整只伴灵。

## 11.2 v1 完成范围

P1 Starter Action 族：

| Action | 作用 | 播放契约 |
|---|---|---|
| `gaze` | 光标注视 | 8 帧：顺时针八方向；中心显示 canonical base |
| `rest` | 躺下、睡息、起身 | 9 帧：3 + 3 + 3，慢速 breathing loop |
| `tennis` | 完整正手挥拍 | 9 帧；图中不画球，runtime 只合成一个确定性球 |
| `wall` | 墙边站 / 屏幕边坐 | 6 帧：stand 3 + sit 3；attached surface 驱动 |
| `walk` | 走路 | 8 帧两步闭环；travelled distance 驱动 |

完整约 190 帧的 video-driven inventory 仍是高阶扩展；Starter 只生成 8 个
强 gait key poses，不把长期内容上限变成首次领养门槛。

## 11.3 Artifact contract

Studio 与任何外部 generator 只通过同一个 result bundle 交接：

```text
action-<name>.png
action-<name>.metadata.json
action-<name>.qa.json
action-<name>-contact-sheet.png   # optional but recommended
```

`metadata` 至少包含：

- schema version、action、frame count、cell size、FPS；
- anchor in source-cell coordinates；
- walk 的 authored cycle distance；
- 明确的 `automaticInstallAllowed: false`。

Generator 不能授权安装。Mimo 重新校验文件、尺寸、路径、QA 与 locomotion
metadata，复制进 app-owned storage 后，仍要求用户先 preview 再 accept。

## 11.4 Studio UX

Settings 已用五张动作卡替换旧的本地导入主入口：

- `等待生成 / 生成中 / 本机处理 / 待验收 / 已安装 / 失败`；
- 每条动作显示预计成本、已产生费用、重试次数与 provider；
- canonical master 完成后即可领养，动作在后台逐条补齐；
- 关闭 Settings 或重启 Mimo 后继续显示真实状态；
- 成功返回的每个付费 batch 立刻落盘；重启后明确显示 interrupted；
- 失败/取消后的重试从第一个未完成 batch 开始，不重复已保存的调用；
- preview 永远不等于 install；accept 后原子更新 manifest revision。
- retained raw batches 可用 0 provider calls 本机重做 matte / despill / registration。
- 旧 result-folder 导入保留在 Advanced，不再是普通用户主流程。

## 11.5 已完成的实施顺序

1. **冻结 Starter contract**：五套动作共 40 帧、14 个三帧 batch；
2. **统一 orchestrator**：canonical-first、前一 batch 只作 continuity reference；
3. **batch checkpoint**：成功结果先持久化，再开始下一次 provider call；
4. **Studio 五卡**：预算、状态、取消、断点重试、本机重新抠图、Preview / Accept；
5. **runtime 语义**：gaze mapping、sleep phases、tennis ball、wall stand/sit、walk；
6. **安全安装**：沿用同一 `ActionGenerationJobStore` review boundary。

## 11.6 Release acceptance

使用一个全新的 app data directory：

1. 添加参考图并确认 identity board；
2. 生成并领养 canonical familiar；
3. 逐张点击生成五个 Starter Action；每张开始前都能看到 calls 与成本；
4. 每条动作都能在桌面 preview，失败结果无法安装；
5. 接受通过项后，退出重开仍能加载相同 revision；
6. 中途取消、网络失败、本机处理失败都不会丢 canonical master 或重复扣费；
7. `mac/build.sh` 与 `mac/test.sh` 全绿；
8. 发布包不包含原始个人参考图、provider credential 或本地生成 runs。

## 11.7 暂不包含

- P2 多屏漫游与 P4 窗口地形；
- 多实例、Marketplace、Windows；
- 用通用聊天替代 companion behavior；
- 为达到固定帧数而静默重掷或降低 QA 阈值。
- 自动替用户触发付费生成；P1 始终要求用户在卡片上明确点击。
