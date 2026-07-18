> 伴灵模式计划 · 模块文档 — [索引与阅读顺序](README.md)
> 章节编号(§0–§7)沿用拆分前的全局编号,跨文件引用见索引的对照表。

## 2. Mimo 现状 & 瓶颈

### 2.1 现状(读码结论)

| 层 | 现状 | 位置 |
|---|---|---|
| 宿主 | 单个 560×320 无边框 NSPanel,右下角,statusBar 层,全 Spaces,默认鼠标穿透 | `main.swift` `buildPanel()` |
| 命中 | 10Hz 轮询鼠标是否在写死的 260×265"热区"内,动态切 `ignoresMouseEvents` | `main.swift` `startHoverTracking()` / `creatureRect()` |
| 拖拽 | JS 检测 >8px 位移发 `dragStart`,Swift 60Hz timer 让整个 panel 跟随鼠标;松手落在屏幕边缘 40px 内则收起 | `overlay.html` pointer handlers、`main.swift` `beginDrag()/endDrag()` |
| 自主移动 | 仅 victory walk:升级时 Swift 用 smoothstep 把 panel 扫到屏幕左缘再回来,JS 播 waddle | `main.swift` `victoryWalk()` |
| 状态机 | 前台 app 分类驱动情绪状态(idle/focused/scholar/dizzy/poisoned/ghost/evolved),1Hz focus 引擎,streak/XP/等级 | `overlay.html` `Fam` + focus engine |
| 渲染 | WKWebView:像素包(网格字符串+调色板,代码绘制 SVG)与 raster 包(生成的 1536×512 sheet,3 阶段 × 3 表情帧),状态 → CSS keyframes + 滤镜 | `overlay.html` `Mascot` / `rasterMascotPack()` |
| 环境感知 | 前台 app bundle id + 浏览器 tab URL(分类用),**无窗口几何**;多屏只用于 panel 复位钳制 | `main.swift` `watchApps()` / `panel_geometry.swift` |

### 2.2 瓶颈(对照 Shimeji)

| 维度 | Shimeji | Mimo 现状 |
|---|---|---|
| 行为多样性 | 数据驱动,数十个加权行为,环境门控 | 硬编码,一个情绪 switch,零自主行为 |
| 物理 | 重力/抛掷/弹簧拖拽/扫掠碰撞 | 无;拖拽是 1:1 平移,松手无惯性 |
| 移动 | 走/爬/跳/坠,anchor + 每帧 Velocity | panel 整体平移,仅两条脚本路径 |
| 地形 | 屏幕边 + 前台窗口四边,统一 Border 抽象 | 无概念;creature 固定在 panel 右下 |
| 打断 | 统一规则,任何时刻可抓起 | 拖拽可用,但没有"世界变化"中断 |
| 多屏 | 走得过去,缝边跳过 | panel 级恢复钳制(已做得不错),creature 无感知 |
| 多实例 | Manager + Breed + affordance 握手 | 单实例 |
| 资源包 | Pose(anchor/velocity/duration)+ 条件动画 + hotspot | 3 静态帧 + CSS;**没有运动帧** |
| 手感 | 拎起会晃、会挣扎、扔出去会飞 | 拎起是搬一块玻璃板 |

### 2.3 Mimo 已有而 Shimeji 没有的(要保住的资产)

- **语义环境感知**:app/tab 分类、focus 引擎、streak、XP/进化 —— Shimeji 的
  环境只有几何,Mimo 的环境有*意义*。这是差异化核心。
- 付费生成 pipeline(3 阶段进化 + 表情 sheet)与三种资源 lane 的雏形。
- panel 位置恢复/多屏钳制的健壮性工作(`panel_geometry.swift` + 测试)。
- 日志/journal/复盘系统,以及"不打扰"的产品气质。

---

## 3. 设计原则(Mimo 伴灵 2.0 的立场)

1. **专注时安静,空闲时活泼。** Shimeji 的漫游天生是干扰源;Mimo 知道你
   在深工作。行为权重被情绪层调制:`deepWork` 状态下漫游行为权重 → 0,
   伴灵回到角落安静待机(呼吸/偶尔看你一眼);`idle`/`neutral` 才解锁
   走动、爬窗、耍宝。**这是本计划最重要的产品决策。**
2. **物理只为手感服务。** 照抄 Shimeji 的取舍:真积分只给 Fall/Thrown,
   跳跃弧线和落地弹跳用便宜的假动作。
3. **一条打断规则。** 抓起/松手/失地永远立刻接管,任何资源 lane、任何
   行为下都成立。
4. **数据驱动。** 行为、动作、动画、热点全部进资源包(JSON),引擎只
   提供动词;三种 lane(像素/raster/程序化)实现同一渲染协议。
5. **失败自愈。** 一切异常收敛到"落回屏幕底部安全位"(Mimo 的世界观里
   不从天上掉 —— 从屏幕边缘"浮"回来更符合灵体气质,机制等价)。

---

