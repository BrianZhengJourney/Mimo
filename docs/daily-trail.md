# Mimo 今日手记 / Today Journal

今日手记回答三个问题：**时间去哪了、真正推进了什么、什么值得带到明天**。
它不是远程笔记同步器；唯一必需的数据源是 Mimo 已有的本机 activity JSONL。
如果用户已运行 ActivityWatch，可在隐私设置中主动开启 localhost 补充源。

`⌥ Space` 打开的轻量入口称为 **快览 / Quick Look**，用于快速找回刚才的上下文；
**今日手记 / Today Journal** 是完整的回顾空间。

## 产品结构

```text
raw local events
    ↓ lossless sessionization
meaningful activity blocks
    ↓ local graph snapshot
chronological nodes + return edges + semantic clusters
    ├── clustered journey graph
    ├── strict 30-minute chapters
    ├── category/time visualization
    ├── hover context overlays
    ├── expandable raw evidence
    ├── learning material summary overlays
    └── grounded daily reflection
```

- **今日旅程**：相同主题可在 15 分钟内续接；相同大类的快速工具切换会合并为一个
  activity block。每个 block 始终保留全部 raw event ID。
- **Clustered graph**：可切换两种读法。「时间」严格表达发生顺序；「主题」把跨 App/网站
  的相关节点聚在一起。实线是下一步，`return` 是回到同一地方，`topic-return`
  是离开后又接回同一主题。hover 会同时高亮整个主题。
- **半小时轴与 overlay**：图下方保留严格 30 分钟格；可拖到下方形成清晰起止边界。
  activity 与 learning material 在 hover/focus 时展开上下文，键盘也能访问。
- **时间可视化**：Building、Learning、Communication、Planning、Admin、
  Entertainment 六类时间占比、有效时间、专注时间和 context switches。
- **Learning materials**：从 paper、website、video、document 记录中去重，展示来源、
  阅读投入、访问次数和摘要。无 AI 时只陈述标题/来源/投入等可验证元数据，不编造内容。
- **Daily reflection**：先显示一句话与三个问题的本地确定性答案，所有陈述都引用 raw
  event ID；可选 OpenAI enrichment 只做更自然的整理，不是使用门槛。

## 图数据与演进边界

Mimo 现在把每个日期范围保存为 Graphology-compatible JSON：`nodes`、`edges`、
`attributes`，外加可直接绘制的 `clusters`。最多保留 35 个本地图快照，隐私清除会一起
删除。页面使用相同快照绘制，因此图不是临时动画；未来替换渲染器也不会改变数据语义。

```text
Mimo JSONL + optional localhost ActivityWatch
  → normalize + merge heartbeats/short events
  → meaningful blocks (lossless raw IDs)
  → interpretable local topic clusters
  → sequence + identity return + topic return graph
  → cross-day recurrence metadata
  → Today Journal time/topic SVG/DOM renderer
  → Sigma.js only when node count needs WebGL scale
```

- ActivityWatch 已经把活动建模为 bucket + timestamped events，并建议 watcher 用
  heartbeat 合并相邻活动。Mimo 先把它的 window、web tab 和 AFK 记录转换为统一
  canonical event，UI 不依赖 watcher 私有字段（[Buckets and events](https://docs.activitywatch.net/en/latest/buckets-and-events.html)、
  [Working with data](https://docs.activitywatch.net/en/latest/examples/working-with-data.html)）。
- ActivityWatch adapter 是 opt-in，仅读取 `127.0.0.1:5600`；无数据或不可用时会明确显示状态并
  继续使用 Mimo 记录（[ActivityWatch REST API](https://docs.activitywatch.net/en/latest/api/rest.html)）。
- Graphology 的 export/import 形状使本地快照可以在不丢边语义的情况下交给其他 renderer
  （[Graphology serialization](https://graphology.github.io/serialization.html)）。
- Sigma.js 支持在 WebGL 图层上下叠加 SVG/HTML 层；当单日图超过约 300–500 个节点时，
  可换成 Sigma renderer，同时保留 HTML tooltip 与 30 分钟轴
  （[Sigma custom layers](https://www.sigmajs.org/docs/advanced/layers/)）。

当前 topic cluster 是完全本地、可解释的规则：标题关键词、domain、App、大类和时间邻近度共同
决定归属。同一主题在过去日期出现时，今日图只保留「出现过几天 / 最近何时」，不把历史
原始事件复制进当日 payload。下一步是用户手动合并、拆分、改名，再评估是否需要本地 embedding。

## 隐私边界

- 不新增录屏、键盘记录或网页正文抓取。
- 原始 URL 只在展开证据和主动打开来源时留在本机界面。
- 可按 App/domain 排除活动；排除不删除原始日志。
- 关闭 ActivityWatch 只停止 Mimo 读取；不会删除 ActivityWatch 自己的历史。
- 每次 AI 请求都先经过原生确认框。仅发送当前日期范围的活动元数据；URL credentials、
  fragment 和 token/secret/auth/session 等敏感 query 会先移除。
- Provider storage 显式关闭；没有 API Key 时本地旅程、可视化、材料卡片和 reflection
  均正常工作。
- 当前版本没有远程笔记连接、同步或写回路径。

## 构建与离线 fixtures

```bash
./mac/build.sh
./mac/build/Mimo.app/Contents/MacOS/Mimo --reflection-fixture=1
./mac/build/Mimo.app/Contents/MacOS/Mimo --reflection-fixture=empty
./mac/build/Mimo.app/Contents/MacOS/Mimo --reflection-fixture=error
./mac/build/Mimo.app/Contents/MacOS/Mimo --reflection-fixture=nokey
```

fixture 模式不读取真实 activity，不启动产品追踪，也不发模型请求。真实 WKWebView DOM
门禁可在解锁的 macOS 会话运行：

```bash
MIMO_RUN_GUI_TESTS=1 ./mac/test.sh reflection_browser_dom
```

## MVP 之后

1. 用户校正 activity title/category/cluster，形成可学习的本地规则；
2. 支持 activity block 与 graph cluster 合并、拆分、改名；
3. 将跨日主题关系升级为可编辑的本地 project map；
4. 在明确授权下获取网页正文，提升材料摘要质量；
5. 将导出作为可选 destination，而非核心体验依赖。
