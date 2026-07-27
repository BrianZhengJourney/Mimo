> 伴灵模式计划 · §11 — [索引](README.md)

# 11. 完整 Custom Pet Generation

**状态：下一实施里程碑（2026-07-27）。**

目标不是再做一条独立生成 demo，而是把已经验证过的 canonical character、
action production、hard QA、preview 与 manifest 安装接成一个用户可恢复的
Mimo Studio 流程。

## 11.0 当前接缝

已经存在：

- `reference_preprocessor.swift`：在本机整理与确认身份证据；
- `PetGenerationCoordinator`：生成 canonical master / expression assets；
- `action_sheet.swift` 与 `skills/mimo-animate-pet/`：动作生产与确定性后处理；
- `ActionGenerationJobStore`：安全导入、持久化、preview、QA、显式接受；
- `CustomPetStore` manifest v2：按动作名安装 strip 与播放元数据；
- `CompanionRuntime`：加载多 action strip，由行为包按名字播放。

尚未接通：

- Studio 在 canonical master 后仍显示 `Action frames` placeholder；
- action job 只能从本地 result folder 导入，不能由 Studio 发起；
- 多动作生成没有统一的进度、预算、重试与重启恢复视图；
- 完成定义仍分散在 image-sheet、Wan 和 hybrid 实验中。

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
atomic manifest v2 install
      ↓
behavior pack drives the native companion
```

每个 action family 是独立 artifact。某个动作失败时，用户仍可使用 canonical
master 与已经通过的动作；不得因为一格或一条失败而重做整只伴灵。

## 11.2 v1 完成范围

必需动作族：

| Action | 作用 | 播放契约 |
|---|---|---|
| `walk` | 基础移动 | 按距离驱动；必须有 authored cycle distance |
| `gaze` | 光标注视 | 慢速 authored holds；左右可安全镜像 |
| `rest` | 躺下、睡息、起身 | 起手/循环/收尾可链式播放 |
| `wall` | 左右墙倚靠 | attached surface 驱动；右墙镜像 |

签名动作（如 tennis / tea / book）作为生成完成后的增量包，不阻塞首次领养。
完整约 190 帧的 inventory 仍是内容上限，不是 v1 activation 门槛。

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

把当前 `Action frames` placeholder 替换为动作卡片：

- `等待生成 / 生成中 / 本机处理 / 待验收 / 已安装 / 失败`；
- 每条动作显示预计成本、已产生费用、重试次数与 provider；
- canonical master 完成后即可领养，动作在后台逐条补齐；
- 关闭 Settings 或重启 Mimo 后继续显示真实状态；
- 失败只提供“本机重处理”或“重新付费生成”两个明确动作，不混淆；
- preview 永远不等于 install；accept 后原子更新 manifest revision。

## 11.5 实施顺序

1. **冻结 contract**：选一份通过 QA 的 fixture，确保 image-sheet / hybrid /
   video 后端都输出同一 bundle。
2. **统一 orchestrator**：以 canonical master、temperament、body plan 生成
   action plan；每条 action job 独立入 ledger 与 draft store。
3. **接 Studio**：从 canonical result 直接创建动作 jobs，替换本地文件夹导入
   作为主入口；开发者导入保留在 debug/advanced。
4. **恢复与花费**：接入现有 reservation、timeout、cancel、retry ceiling，
   重启后从持久化状态恢复，不重复付费。
5. **安装事务**：逐动作验收，写临时 manifest，完整校验后 rename 覆盖；
   已安装 revision 在任何失败路径下都保持可用。

## 11.6 Release acceptance

使用一个全新的 app data directory：

1. 添加参考图并确认 identity board；
2. 生成并领养 canonical familiar；
3. 后台生成四个必需动作族；
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
