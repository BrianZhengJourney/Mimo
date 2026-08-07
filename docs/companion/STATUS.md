# Mimo 当前状态

> 唯一的当前状态入口。最后核对：2026-08-07。其余 companion 文档保留设计和
> 实验历史；与本页冲突时，以本页和代码为准。

## 可用 baseline

- 分支：`codex/walk-rig-prototype`。
- 产品版本：`0.2.0 Alpha`，`mac/build/Mimo.app` 可直接运行。
- 角色：多张参考图 → 本机自动找人物 → identity/style board → canonical
  familiar → 默认动作包。
- 默认动作：注视 8 帧、趴睡 6 帧、网球 9 帧、墙边站/坐 6 帧；一次点击后
  顺序生成，仍需逐个预览并接受后才会安装。
- 已移除：等级、XP、升级资源、level-up/火苗/连续专注 HUD、
  Quest/冒险手记、victory walk 与走路正式入口、旧动作实验预览菜单、
  正式版 PixelLab key 配置。
- Focus：本地活动分类、25/50 分钟专注计时、快览、今日手记、周视图和
  导出继续保留。伴灵不随机游走；深度工作、分心回访、Focus 完成、连续疲劳和回看
  手记都是稀疏、有冷却的语义事件。

## 今日手记与 Recurrence

- 唯一必需数据源是 Mimo 本机 activity JSONL；ActivityWatch 仅是用户主动开启的
  `127.0.0.1` 补充源。没有 Notion 连接、启动同步或写回路径。
- 原始事件无损合并为 activity blocks，再保存为有 sequence / identity return /
  topic return / cross-day recurrence 的本地 graph 快照。主题视图默认展示可读
  主线和空间 cluster；时间视图与严格 30 分钟轴保留精确顺序。主题可本机改名、
  合并或恢复自动整理；校正在刷新/重启后保留，不改写 raw event。
- 回看优先回答“时间去哪了 / 真正推进了什么 / 带什么到明天”；可选
  OpenAI 只在本机 scope confirm 后整理 URL-scrubbed metadata，无 Key 时完整本地功能
  仍可用。
- 伴灵 context policy 区分“三次回到分心内容”与“三分钟内八次切换”，
  提醒冷却 20 分钟；连续活动 90 分钟才提示休息，锁屏、离开、Pause 都会切断
  连续时间。Focus 完成有一次本地庆祝；无网球动作的非人形角色使用通用
  小庆祝，无趴睡动作时使用原地呼吸。
- 完整今日手记可见期间，伴灵持续处于 `reflecting` 状态；关闭或最小化后
  恢复最新的底层 Focus/activity 状态，而不是只做一次 8 秒动画。

## 质量 baseline

2026-08-07 非 GUI 工程门：`./mac/test.sh` 为 **61 passed，1 GUI-skipped**；
解锁 macOS 下的 real WKWebView DOM 门禁另行实际执行，为
**1 passed / 0 skipped**。`./mac/build.sh` 成功生成完整 App bundle。构建内
明确写入 commit、dirty 与 signature mode；当前仍是 ad-hoc temporary signature，
稳定本地签名必须等用户明确授权 Keychain 私钥与仅限 `codeSign` 的信任。

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

本机质量门已通过。counterbalanced provider cohort 已累计 baseline/candidate
各 30 calls：candidate p95 `99.762s`、baseline p95 `93.702s`，比值
`1.065×`，成本比 `1.0×`，通过 `<= 1.10×` 门槛。旧 sleep rev-2 在 3 个
sleep packs 中出现 1 次右侧裁切；rev-3 使用相同人物/styleboard 的定向 cohort
达到 24/24 calls 成功、12/12 packs 通过、右侧裁切 0，p95 `50.424s`。
仍需把 rev-3 跑过完整固定数据集并写入 rollout ledger，才可推进正式比例。

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

1. 经用户明确授权后创建稳定的 `Mimo Local Development` 签名，验证重建后
   Keychain 与 Automation 授权不再重置。
2. 让用户可以拆分 topic cluster，或把单个 activity 移入/移出主题，再评估本地 embedding。
3. 在伴灵界面中解释“它为什么正在这样做”，而不增加更多随机动作。
4. 跑 sleep rev-3 完整固定数据集并写入 `5% → 25% → 100%` rollout ledger。
