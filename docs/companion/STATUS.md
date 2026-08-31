# Mimo 当前状态

> 唯一的当前状态入口。最后核对：2026-08-31。其余 companion 文档保留设计和
> 实验历史；与本页冲突时，以本页和代码为准。

## 可用 baseline

- 稳定集成分支：`main`。原 `codex/walk-rig-prototype` 与
  `codex/apple-photos-companion-prototype` 已完整 fast-forward 进入 `main`，
  不再承担独立 release baseline。
- 产品版本：`0.2.0 Alpha`，`mac/build/Mimo.app` 可直接运行。
- 角色：照片图库或手工多图 → 本机找人物与聚类 → 主参考 / 辅助参考 →
  identity/style board → canonical familiar → 默认动作包。照片工作流会在领养后
  清空上一位主角的临时图片，并保持窗口可直接开始下一项目。
- 默认动作：注视 8 帧、趴睡 6 帧、网球 9 帧、墙边站/坐 6 帧；一次点击后
  顺序生成，仍需逐个预览并接受后才会安装。已安装动作可从伴灵管理器显式
  重生成；旧动作会保留到新版安装成功。桌面菜单的跟随光标与墙边站/坐都是
  可见、可退出、确定性的手动模式，不依赖随机行为抽中。
- Studio：同轮 Low 候选完整保留并可切换；删除、排序或更换主参考不会自动
  产生新请求。同名伴灵作为独立角色展示、排序和管理，不再折叠成一个版本组。
- 已移除：等级、XP、升级资源、level-up/火苗/连续专注 HUD、
  Quest/冒险手记、victory walk 与走路正式入口、旧动作实验预览菜单、
  正式版 PixelLab key 配置。
- Focus：本地活动分类、25/50 分钟专注计时、快览、今日手记、周视图和
  导出继续保留。伴灵不随机游走；深度工作、分心回访、Focus 完成、连续疲劳和回看
  手记都是稀疏、有冷却的语义事件。

## 当前 UI

- 状态条按角色当前帧的实际非透明区域定位，贴近伴灵头顶；`560 × 440` 透明承载区
  给大尺寸角色、状态条和阴影留足空间，不再被裁切。
- 状态条可点 `×` 关闭，也会在 30 秒后自动隐藏；悬停或打开 Quick Look 时暂停。
  显示时参与鼠标命中，隐藏后恢复 click-through。
- Quick Look 与 Settings 已统一为暖白、墨色、低饱和朱红的日式极简视觉。
  Quick Look 支持刷新、`Esc` 关闭和左右键切换 Today / Week；Settings 保留稳定
  的粘性 tab、active state 与平滑回顶。

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

2026-08-31 UI 收口后的 `main` 非 GUI 工程门：`./mac/test.sh` 为
**65 passed，1 GUI-skipped**。此前解锁 macOS 下的 real WKWebView DOM 门禁
另行实际执行，为 **1 passed / 0 skipped**。`./mac/build.sh` 成功生成完整 App
bundle。构建内明确写入 commit、dirty 与 signature mode。`Mimo Local Development`
证书与不可导出私钥已经导入用户 Keychain；仅限 `codeSign` 的 trust 仍需用户在
macOS 安全弹窗中确认，确认后还必须连续重建两次验证 Keychain 与 Automation
授权稳定。

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
open -na "$(pwd)/mac/build/Mimo.app"
```

`git status` 除本地私有文件外应没有待提交代码，`git log -1` 应与远端当前
分支 head 一致。每个产品 commit 都必须重新执行 `./mac/build.sh`。

## 朋友友测版门槛

1. 完成 `Mimo Local Development` trust，并连续构建 / 启动两次，确认本机 API Key
   与浏览器 Automation 授权不再因重建失效。这个身份只解决开发机稳定性，不能
   代替给朋友分发所需的 Developer ID / notarization。
2. 用一个全新的 macOS 用户或第二台 Mac 跑黄金路径：首次设置 → 权限 → 今日手记 →
   Photos 找人 → Low 候选 → 定稿领养 → Starter Actions → 重启恢复。付费生成必须
   继续由用户显式开始。
3. 友测前只新增两项产品能力：一页式首次运行 checklist（权限、OpenAI Key、费用与
   本地隐私边界）和“导出诊断包”（build commit / signature、非敏感错误、最近一次
   job 状态；不含参考图、API Key、窗口标题或 URL）。
4. 选择 Developer ID + notarization，或给封闭友测提供明确的一次性 Gatekeeper
   打开说明。不要把自签名本地证书发给朋友信任。
5. 跑 sleep rev-3 完整固定数据集并写入 `5% → 25% → 100%` rollout ledger；
   在此之前不扩展更多 Action Packs、topic embedding、多屏漫游或分享市场。
