# Mimo 米墨

一个 local-first 的 macOS 桌面伴灵：安静陪伴专注、记录被打断的上下文，并把人物、宠物或原创角色做成可交互伴灵。

> **当前版本：v0.2 Alpha · `main` · 2026-08-31。** 真实运行入口是仓库内的 `mac/build/Mimo.app`；不要再复制或启动 `/Applications` 里的旧开发版。

## 现在能做什么

- **桌面伴灵**：原生 AppKit/CALayer 渲染，支持透明像素命中、拖拽/抛掷、屏幕边界、注视和数据驱动行为。
- **专注与回看**：本地活动分类、25/50 分钟 Focus、Quick Look、今日手记、周视图和独立 HTML 导出。
- **DIY Studio**：照片或手动参考图 → 人物候选 → canonical familiar → Starter Actions → 本机 QA → 预览 → 显式接受安装。
- **Starter Actions**：注视、趴睡、网球、墙边站/坐；付费请求永远由用户显式开始，失败或中断不会静默重放。
- **当前交互**：状态条贴近伴灵头顶，可手动关闭或 30 秒自动消失；点击打开日式极简 Quick Look，支持刷新、`Esc` 关闭和左右键切换；Settings 也已统一为克制的日式层级。

## 构建与运行

```bash
./mac/test.sh
./mac/build.sh
open -na "$(pwd)/mac/build/Mimo.app"
```

`build.sh` 默认 ad-hoc 签名。需要跨重建保留 Keychain 与浏览器 Automation 授权时，设置 `MIMO_SIGN_IDENTITY` 使用本机稳定证书。开发 build 用 Git commit 区分，不用同为 `0.2.0` 的版本号判断新旧。

## 产品边界

- 活动历史、聚类修正、Studio job 与草稿默认留在本机。
- 只有用户确认参考图并开始生成后，所选素材才会发送给 provider。
- 可选 AI 回看只发送经过确认、去 URL 的有限元数据；没有 API Key 时本地功能仍完整可用。
- 生成动作必须通过本机 QA 和桌面预览，再由用户接受；现有已安装资产在替换成功前保留。

## 数据流

```text
工作上下文 ──→ Quick Look ──→ 今日手记 / Focus 语义
                                  │
参考图 ──→ identity board ──→ canonical familiar ──→ action families
                                  │
                                  └─→ 本机 QA ──→ 预览 ──→ 原子安装
```

## 仓库导航

- `mac/`：原生 App、伴灵 runtime、Studio、测试和动作工具。
- `docs/companion/STATUS.md`：唯一当前状态与发布门槛。
- `docs/companion/SESSION-HANDOFF.md`：给下一次开发会话的短交接。
- `docs/daily-trail.md`：今日手记的数据流和隐私边界。
- `mac/evals/`：固定数据集、质量门和 rollout ledger。
- `artifacts/wan/README.md`：本地 Wan 运行产物的保留结构。
- `index.html` / `styles.css` / `js/`：已归档的早期浏览器概念，不是发布入口。

更完整的架构索引见 [伴灵文档](docs/companion/README.md)，当前事实以 [STATUS](docs/companion/STATUS.md) 和代码为准。
