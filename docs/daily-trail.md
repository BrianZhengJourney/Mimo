# Mimo 今日手记 / Today Journal

今日手记回答三个问题：今天实际做了什么、时间流向哪里、接触了哪些学习材料。
它不是远程笔记同步器；唯一必需的数据源是 Mimo 已有的本机 activity JSONL。

`⌥ Space` 打开的轻量入口称为 **快览 / Quick Look**，用于快速找回刚才的上下文；
**今日手记 / Today Journal** 是完整的回顾空间。

## 产品结构

```text
raw local events
    ↓ lossless sessionization
meaningful activity blocks
    ├── proportional journey ribbon
    ├── morning/afternoon/evening chapters
    ├── category/time visualization
    ├── hover context overlays
    ├── expandable raw evidence
    ├── learning material summary overlays
    └── grounded daily reflection
```

- **今日旅程**：相同主题可在 15 分钟内续接；相同大类的快速工具切换
  会合并为一个 activity block。每个 block 始终保留全部 raw event ID。
- **Journey ribbon**：每段宽度对应真实投入，按活动类别着色；悬停显示时间、工具和
  上下文，点击会定位到详细活动。
- **日间章节与 overlay**：活动按上午、下午、晚上分章；activity 与 learning material
  卡片在 hover/focus 时展开上下文或核心观点，键盘也能访问。
- **时间可视化**：Building、Learning、Communication、Planning、Admin、
  Entertainment 六类时间占比、有效时间、专注时间和 context switches。
- **Learning materials**：从 paper、website、video、document 记录中去重，展示来源、
  阅读投入、访问次数和摘要。无 AI 时只陈述标题/来源/投入等可验证元数据，不编造内容。
- **Daily reflection**：本地确定性版本始终可用，所有陈述都引用 raw event ID；可选的
  OpenAI enrichment 生成更自然的活动与材料摘要。

## 隐私边界

- 不新增录屏、键盘记录或网页正文抓取。
- 原始 URL 只在展开证据和主动打开来源时留在本机界面。
- 可按 App/domain 排除活动；排除不删除原始日志。
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

1. 用户校正 activity title/category，形成可学习的本地规则；
2. 支持 activity block 合并/拆分；
3. 在明确授权下获取网页正文，提升材料摘要质量；
4. 将导出作为可选 destination，而非核心体验依赖。
