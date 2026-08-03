# Reflection Browser MVP

Reflection Browser 是 Mimo 现有 Today / Week 手记的深度回望层，不是新的
日记 App。Notion 继续保存用户写下的原文；Mimo 保留本机活动轨迹，并在用户
选择的日期与证据范围内比较“我如何描述这段时间”和“实际发生了什么”。

## 打开与设置

- 在小手记底部点 **深度回望 ↗**，或从菜单栏 Mimo 菜单选择
  **深度回望…**。
- 点 **连接**，粘贴 Notion Internal Integration Token 和已共享给该
  Integration 的 page / database URL，然后保存并同步。
- Token 只进入 macOS Keychain。目标 URL、同步缓存、标记和未写回草稿保存在
  Mimo 的本机 ReflectionBrowser 目录。
- AI 分析复用“设置 → API 连接”里的 OpenAI Key。没有 Key 时，activity
  浏览、Notion 同步与搜索仍可使用；分析入口会保持禁用，界面不会用离线模板
  或伪造回答冒充模型成功。

原生离线 fixtures 不导入真实 activity / Notion cache，也不会发 Notion 或模型
网络请求；bridge 在 fixture 模式只接受 `ready`，启动后会直接打开回望窗口：

```bash
./mac/build.sh
./mac/build/Mimo.app/Contents/MacOS/Mimo --reflection-fixture=1
./mac/build/Mimo.app/Contents/MacOS/Mimo --reflection-fixture=empty
./mac/build/Mimo.app/Contents/MacOS/Mimo --reflection-fixture=error
./mac/build/Mimo.app/Contents/MacOS/Mimo --reflection-fixture=notoken
```

也可在运行同一 binary 时设置
`MIMO_REFLECTION_FIXTURE=1|empty|error|notoken`；fixture 进程关闭后再启动下一套。
解锁的本机可运行真实 WKWebView DOM 门禁：

```bash
MIMO_RUN_GUI_TESTS=1 ./mac/test.sh reflection_browser_dom
```

默认完整测试仍会编译这项，但在无 GUI / sandbox runner 中标为 `GUI-skipped`。

2026-08-03 已在解锁的 macOS 会话中完成 populated、empty、error、notoken 四套
原生 fixture 的视觉验收，并覆盖 `980×640` 最小窗口尺寸。fixture 验收不等同于
真实服务 smoke test：当前源码的 real WKWebView DOM 门禁已按上面的命令通过
（`1 passed / 0 skipped`）；Notion token 与 OpenAI live 请求仍需在真实配置下
另行验证。

## 数据流

```text
activity-*.jsonl ──parse/filter──┐
                                ├── evidence IDs ── synthesis / dialogue
Notion page/data source ──cache──┘                         │
                                                          └── preview → confirm → Notion
```

- 左栏始终可以展开到原始事件：时间、App、标题、完整 URL、domain、分类、
  canonical label、顺序、重复访问和上下文切换不会被聚合结果替代。
- 中栏缓存标题、日期、类型、原始 Markdown、page ID / URL 和同步时间；优先
  读取当前 Notion Markdown API；`unknown_block_ids` 会继续从相同 Markdown
  endpoint 读取并替换回原占位位置，权限 404 会保留为可见缺口；只有 endpoint
  不支持时才递归 blocks。同步处理分页、10,000-row incomplete 响应与
  `last_edited_time` 增量刷新。
- 右栏的每条 fact / quote / inference 都必须引用可解析 evidence ID。点击引用会
  回到 activity event 或 Notion 原文。模型输出不满足六段结构或引用未知证据时，
  整份结果会被拒绝；quote 还必须是已选 Notion 原文中逐字存在的单一引用。
  Highlight 会保留在后续 synthesis draft；被标记的历史回复
  继续可见、可删除，Underline 会带入下一轮追问。跨范围时，Highlight 只有在
  它绑定的全部来源 evidence 仍包含于新一轮明确确认的范围内才会带入；否则只留
  在本机历史，不进入模型或写回。
- 从早期 v1 本地状态升级到 v2 时，Mimo 会保留 Notion 连接、日期范围和隐私排除
  设置，但清空旧的派生 conversation / synthesis / marks / writeback preview；这是
  为了防止旧版中缺少来源绑定的 Highlight 被错误带入新 evidence scope。

## Privacy 与写回边界

- Mimo 不新增录屏、键盘记录或网页正文抓取；raw activity 仍留在本机。
- UI 可查看完整 URL；结构化 URL、Notion Markdown、excerpt、prompt 和同范围
  对话中的 URL 在进入模型前都会移除 credentials、fragment 以及明显的
  token / secret / auth / session 等 query 参数；无法解析的 URL 会整体隐藏，
  redirect / next 参数中的嵌套 URL 也会递归清洗。
- 用户可设置忽略的 App 与 domain。排除只影响回望/模型范围，不删除原始日志。
- 每次真实模型请求前，原生确认框会列出日期、activity、Notion reflection 和
  evidence 数量；取消不会发起网络请求。
- “写回 Notion”先生成本地 preview。多个来源页时必须按标题明确选择目标；MVP
  只有再次点击 **确认写回** 才会向该 page 末尾追加 `Mimo Synthesis`，不会把
  database/data-source 容器当 page，也不覆盖原文。最终目标、evidence links、
  marks 与正文共同生成 idempotency key；Notion Enhanced Markdown 内的远端 marker
  + 本机 ledger 防止并发或跨启动重复。若 marker continuation 因权限不可见，
  写回会 fail closed 而不会猜测“尚未写过”。失败保留完整 draft，独立 child
  page 写回暂不开放。
- “删除全部”会清 activity、Notion 本机 cache 和回望衍生数据，并暂停启动自动
  导入；保留的连接只有在用户下一次手动 Sync 后才会重新导入。Pause 会先关闭
  当前活动段，Forget 后的后续记录从删除完成时重新起算。
- Token、reflection 正文和 URL 不进入调试日志或 UserDefaults。

## MVP 边界与后续

当前 Alpha 使用 Internal Integration Token、启动时一次刷新和手动 Sync。若
database URL 没有 view ID、无法从 URL 判断类型，在连接抽屉的“目标类型”
明确选择 **Database**；data source 同样可选 **Data source**。高级用法仍支持
`database:<uuid>` 与 `data_source:<uuid>`。
下一阶段建议依次加入：

1. Notion OAuth，按 workspace 授权并支持撤销；
2. webhook / event-driven 增量更新，减少启动轮询；
3. paragraph/block 级引用与更细的 Notion 定位；
4. 可视化管理多个 Reflection data source；
5. 本机模型选项、保留期和按来源导出/遗忘控制。

OAuth/Webhook 上线前，Internal Integration 必须保持最小页面共享范围，且任何
远端写入继续保留 preview + explicit confirm 两道门。
