# Mimo 当前状态

> 唯一的当前状态入口。最后核对：2026-08-03。其余 companion 文档保留设计和
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
- Focus：本地活动分类、25/50 分钟专注计时、今日完整手记、周视图和
  导出继续保留；小手记只保留 Today / Week 两个范围，并从两处提供
  “深度回望”入口。

## Reflection Browser MVP

- 已集成到现有 AppKit App：可调整大小的三栏窗口并排展示 raw activity、
  Notion 原始手记和 evidence-linked synthesis；不是独立 App。
- Activity 保留时间、App、标题、完整 URL/domain、分类、canonical label、
  顺序、revisit/context switch；聚合可无损展开。支持 Today、rolling Week、
  自定义日期、搜索以及 App/domain/category filter。
- Notion Alpha 支持 page、database 和 data source URL，Internal Integration
  Token 只存 Keychain；使用 `2026-03-11` API、Markdown-first/block fallback、
  全分页、`last_edited_time` 增量原子缓存、启动刷新与手动同步。
- 分析复用设置里的 OpenAI Key。缺 Key 时浏览/同步/搜索仍可用且不会显示
  伪 AI；真实请求只发送明确选择的证据，发送前显示本机 data-scope 确认，
  URL 会去除 credentials、fragment 和明显敏感 query 参数。
- 输出固定为 Chronology / Themes / Reflection vs Reality / Unresolved Threads /
  Questions Worth Carrying / Evidence；fact、quote、inference 均带可定位 evidence
  ID，quote 还必须逐字匹配已选 Notion 原文。标记按精确文本位置跨后续对话
  保留、删除、带入总结或继续追问；跨 evidence scope 时，只有来源仍全部处于
  新一轮确认范围内的 Highlight 才能进入模型或写回。v1 → v2 升级会保留连接、
  日期与隐私设置，并 fail-closed 清空旧版缺少可靠来源绑定的派生分析状态。
- Notion 写回必须 preview 后再次 Confirm；多来源时需按标题明确选择 page，MVP
  只向该 page 追加 Mimo Synthesis。最终 preview 内容与目标共同决定幂等 key，
  Enhanced Markdown 远端 marker + 本机 ledger 提供并发及跨启动幂等，失败保留
  本地草稿；database/data-source 容器 ID 不会被当作可写 page。独立 child page
  尚未开放。
- 隐私设置可排除 App/domain；现有“忘掉上一小时/今天/全部”会同步失效依赖
  已删 activity 的 synthesis、marks 和 conversation；全部删除还会清掉导入的
  Notion 本机缓存，不删除 Notion 原文；删除后自动刷新保持暂停，直到用户手动
  Sync。Pause/Forget 不会再由开放 checkpoint 重建已暂停或已删区间。
- 原生离线 fixtures：`--reflection-fixture=1|empty|error|notoken`。详细命令、
  边界与设置见 `docs/reflection-browser.md`。

## 质量 baseline

2026-08-03 非 GUI 工程门：`./mac/test.sh` 为 **56 passed，1 GUI-skipped**；
`./mac/build.sh` 成功生成并签名 `mac/build/Mimo.app`。Reflection Browser 的
core、Notion、model 和 UI contract 测试均通过。解锁 macOS 后，populated、
empty、error、notoken 四套原生 fixture 已完成视觉验收，包括 `980×640` 最小
窗口尺寸。当前源码的 real WKWebView DOM 门禁也已在可用 GUI 会话中通过：
`1 passed / 0 skipped`。未使用真实 Notion token，也未调用 OpenAI live 模型；
两项 live smoke 仍需真实配置。

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

1. 用一个最小权限 Notion test workspace 做 page 与 data-source live smoke
   test；OpenAI live smoke 也需真实 Key。
2. Reflection 下一阶段：Notion OAuth、webhook 增量刷新、block/paragraph 级引用
   和多 data-source 管理；在此之前继续保留 preview + explicit confirm 写回门。
3. 跑 sleep rev-3 完整固定数据集并写入 `5% → 25% → 100%` rollout ledger。
4. 保持默认动作一键生成，把失败恢复和“从断点继续”做成普通用户无压力的路径。
