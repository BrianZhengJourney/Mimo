> 伴灵模式计划 · §12 — [索引](README.md)

# 12. Starter Actions：实施记录与验收

**状态：P1 代码完成（2026-07-28）；待首只真实 DIY 伴灵的付费生成与视觉验收。**

## 12.0 用户路径

```text
领养 DIY 伴灵
      ↓
自动建立 4 张动作卡（不花钱）
      ↓ 用户逐卡点击
显示 calls / quality / 预计成本
      ↓
3-frame batch → 立即 checkpoint → 下一 batch
      ↓
本机统一 scale / baseline / anchor
      ↓
hard QA → 桌面 Preview → 用户 Accept
      ↓
原子安装进该伴灵 manifest
```

用户不需要 CLI、Python、Modal 或手工 result folder。外部导入只留在 Advanced。

## 12.1 P1 合同

| 卡片 | Manifest key | 帧 | Calls | Runtime 语义 |
|---|---|---:|---:|---|
| 跟随光标 | `gaze` | 5 | 2 | neutral / up / right / down / left |
| 睡觉 | `rest` | 9 | 3 | lie-down 3 → breathe 3 → rise 3 |
| 打网球 | `tennis` | 9 | 3 | 一次完整正手；球由 runtime 确定性合成 |
| 墙边站 / 坐 | `wall` | 6 | 2 | wall-stand 3 / ledge-sit 3 |

总计 29 帧、10 个显式 provider calls。四张卡互相独立；任何一张失败都不影响
canonical familiar 或已安装动作。

## 12.2 Durable 状态机

```text
planned → queued → generating → local_processing → awaiting_review → installed
                    │                    │
                    ├── failed ←─────────┘
                    └── cancelled

failed / cancelled --用户点击 Resume--> queued
```

- 每个 provider batch 使用独立 idempotency key；
- 成功图片先 checkpoint，再允许下一次调用；
- App 中断不会自动续费：重启后 active job 变 `failed/interrupted`；
- Resume 保留 `completedBatches` 与 `usedProviderCalls`；
- 最多 3 次显式 attempt；没有静默重掷；
- Preview 不安装；只有 Accept 才更新 manifest。

## 12.3 真实验收

```bash
cd "/Users/brianzheng/Desktop/GitHub/Mimo 米墨"
./mac/test.sh
./mac/build.sh
open "./mac/build/Mimo.app"
```

App checklist：

1. `◐ → Settings`，选择或新建一个 DIY 伴灵；
2. Starter Actions 出现 gaze / sleep / tennis / wall 四张卡；
3. 先生成一张，确认开始前可见 calls、quality 与预计成本；
4. 生成中关闭再打开 Settings，状态和已完成 batch 仍在；
5. 结果进入待验收后先点 Desktop Preview，确认没有自动安装；
6. gaze：光标在上/右/下/左时方向正确；
7. sleep：躺下、慢呼吸、起身连贯，没有 scale pop / baseline hop；
8. tennis：完整正手，画面中始终只有一个球，loop seam 无重复球；
9. wall：撞左右墙可站靠；ledge-sit 使用后 3 帧；
10. Accept 后退出重开，动作 revision 仍能加载。

视觉不通过时不要 Accept；保留 job/result 作为诊断证据，再决定是 deterministic
本机修复还是显式重新生成一个 coherent batch。

## 12.4 P2 扩展入口

首批四动作稳定后，按以下顺序扩展：

1. **Action packs**：把 optional motion 做成不阻塞领养的独立包；
2. **Creator template**：复用 canonical/action contract，让创作者只定义 motion；
3. **Pet package**：导出 manifest + accepted assets + behavior pack，不含原始参考图；
4. **User access**：签名下载包、版本迁移、可回滚安装、公开/私有分享；
5. **Quality telemetry**：只记录匿名结构指标与用户 Accept/Reject，不上传个人素材。
