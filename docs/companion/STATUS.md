# Mimo 当前状态

> 唯一的当前状态入口。最后核对：2026-07-31。其余 companion 文档保留设计和
> 实验历史；与本页冲突时，以本页和代码为准。

## 可用 baseline

- 分支：`codex/walk-rig-prototype`。
- 产品版本：`0.2.0 Alpha`，`mac/build/Mimo.app` 可直接运行。
- 角色：多张参考图 → 本机自动找人物 → identity/style board → canonical
  familiar → 默认动作包。
- 默认动作：注视 8 帧、趴睡 6 帧、网球 9 帧、墙边站/坐 6 帧；一次点击后
  顺序生成，仍需逐个预览并接受后才会安装。
- 已移除：等级、XP、升级资源、level-up HUD/音效、victory walk、走路生成、
  旧动作实验预览菜单和素材、正式版 PixelLab key 配置。
- Focus：本地活动分类、今日完整手记、周视图和导出继续保留。

## 质量 baseline

固定数据集 `mimo-diy-v3`：160 个 S1/S2/S3 synthetic cases、10 个已付费
retained field cases、2 个 `UNKNOWN` 待归因样本。

| 指标 | Round 003 |
|---|---:|
| Effective success | 100% |
| Field success | 100% |
| Pareto #1 错误 | 20 → 0 |
| Matte primary error | 1.5792% → 1.1910%（-24.58%） |
| 其他 hard class regression | 0 |
| Local p95 ratio | 1.0116× |
| Unit cost ratio | 1.0× |

本机质量门已通过，但还不能声称完整 rollout-ready：历史 field jobs 没有
provider timing。新 job 已记录每次 provider call 的结果、耗时和可能花费；
需有 baseline 与 candidate 两批真实 samples，并验证 provider p95 `<= 1.10×`，
才能按 `5% → 25% → 100%` 推进。

证据：

- `mac/evals/rounds/003-presentation-frame-line.md`
- `artifacts/evals/runs/round-003-full/metrics.json`
- `artifacts/evals/runs/round-003-full/*-contact-sheet.png`

## 如何确认自己运行的是最新版本

`0.2.0` 是产品版本，不足以区分每个开发 build；开发期以 Git commit 为准：

```bash
git status --short
git log -1 --oneline
git rev-parse --abbrev-ref HEAD
./mac/build.sh
open mac/build/Mimo.app
```

`git status` 除本地私有文件外应没有待提交代码，`git log -1` 应与远端当前
分支 head 一致。每个产品 commit 都必须重新执行 `./mac/build.sh`。

## 下一步

1. 用新 telemetry 跑两批小规模真实动作 calls，补齐 provider p95 rollout gate。
2. 保持默认动作一键生成，把失败恢复和“从断点继续”做成普通用户无压力的路径。
3. 保留“一次点击打开今日完整手记、点外关闭”，再把最上方压缩成一眼可懂的
   今日 focus 结论。
