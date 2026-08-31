# Mimo 会话交接

> 当前交接：2026-08-31 · 分支 `main`。先读 [STATUS.md](STATUS.md)；历史实验细节留在对应设计文档和 Git 历史，不再堆进本文件。

## 当前产品

- 真实入口：`mac/build/Mimo.app`。不要复制或启动 `/Applications/Mimo.app` 的旧开发安装。
- 原生 CALayer 伴灵负责渲染、透明像素命中、拖拽/抛掷、物理、注视和行为；WebView 负责 HUD / Quick Look。
- Focus、今日手记、周视图、HTML 导出、Photos / 手工参考图、DIY Studio 与四套 Starter Actions 均在 `main`。
- 付费生成、失败重试、预览接受均要求用户显式操作；不要自动调用 provider 或替用户安装生成结果。

## 2026-08-31 UI 收口

- 状态条以 `primaryCompanionVisualRect()` 的实际非透明像素定位，贴近角色头顶，不再悬在半空。
- overlay 透明承载区扩大为 `560 × 440`，大尺寸角色上方的状态条和阴影不会被窗口裁切。
- 状态条可点 `×` 关闭，30 秒自动消失；鼠标悬停和 Quick Look 打开期间暂停倒计时。
- 状态条会正确参与透明窗口鼠标命中；关闭后恢复 click-through。
- Quick Look 已统一为暖白、墨色、低饱和朱红的日式极简视觉，支持刷新、`Esc` 关闭、左右键切换 Today / Week。
- Settings 使用同一视觉语言：稳定的粘性导航、清晰 active state、平滑回顶、减少 emoji 噪音。
- 对应契约测试在 `focus_surface_ui_test.swift`、`journal_click_ui_test.swift`、`settings_visual_contract_test.swift`。

## 关键文件

| 区域 | 文件 |
|---|---|
| App / HUD 窗口与定位 | `mac/main.swift` |
| 原生伴灵可见区域 | `mac/companion_runtime.swift` |
| 状态条与 Quick Look | `mac/overlay.html` |
| Settings / DIY Studio | `mac/settings.html` |
| 当前发布事实 | `docs/companion/STATUS.md` |
| DIY 安全边界 | `docs/companion/11-custom-pet-integration.md` |

## 验收

```bash
./mac/test.sh
./mac/build.sh
codesign --verify --deep --strict mac/build/Mimo.app
git diff --check
open -na "$(pwd)/mac/build/Mimo.app"
```

视觉验收重点：状态条位于可见头顶、没有裁切；`×` 和 30 秒隐藏都有效；Quick Look 打开时不会消失；`Esc`、左右键、刷新可用；Settings 各 tab 不跳位。

## 下一步边界

优先完成朋友友测 gate：稳定签名/授权、全新 macOS 用户黄金路径、首次运行 checklist、诊断包，以及 sleep rev-3 完整固定数据集与 rollout ledger。不要在这些 gate 前扩张更多 Action Packs、多屏漫游或分享市场。
