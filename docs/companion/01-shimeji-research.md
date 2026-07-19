> 伴灵模式计划 · 模块文档 — [索引与阅读顺序](README.md)
> 章节编号(§0–§8)沿用拆分前的全局编号,跨文件引用见索引的对照表。

## 1. Shimeji 交互模型(浓缩版)

来源:Shimeji-Desktop 源码(`com.group_finity.mascot.*`)、原版 conf、
libshijima、kilkakon.com 的 -ee 文档。

### 1.1 两层结构:Behavior(决策)× Action(执行)

每个角色包两个 XML:`behaviors.xml` + `actions.xml`。

- **Behavior = "接下来做什么"**。带 `Frequency`(相对权重)、`Condition`
  (环境条件)、可嵌套的 `<Condition>` 分组(条件沿树 AND)。选择算法是
  纯加权轮盘:收集所有条件为真的 behavior,按权重随机。
  `NextBehaviorList` 给行为链加马尔可夫倾向(坐下 → 更可能晃腿/躺下;
  `Add="false"` 可做黏性循环,如追鼠标)。四个 behavior 是引擎硬性要求:
  `Fall` / `Dragged` / `Thrown` / `ChaseMouse`。
- **Action = "怎么做"**。原语类型:`Stay`(贴边待着)、`Move`(沿边走向
  TargetX/Y)、`Animate`(播一遍动画)、组合子 `Sequence`(顺序,可 Loop)
  和 `Select`(第一个条件为真的子项,当 if/elif 用),以及 `Embedded`
  (Java 类:Fall、Jump、Dragged、Breed、ScanMove、Look、Offset、
  ThrowIE…约 15 个动词)。所有 action 共享 `Duration` / `Condition`
  (**每 tick 复查,条件变假立即结束**)/ `Draggable`(默认 true)。
  `ActionReference` 可带参数覆盖调用(如 `Duration="${500+Math.random()*1000}"`)。
- **条件表达式 = 嵌在 XML 里的 JS**(Nashorn/Rhino;libshijima 用 duktape)。
  两种求值时机:`${expr}` 在 action init 时求一次并缓存,`#{expr}` 每 tick
  重求。暴露的 API:`mascot.anchor.x/y`、`mascot.lookRight`、
  `mascot.totalCount`、`mascot.environment.workArea/activeIE 的各边`、
  `floor/wall/ceiling.isOn(point)`、`cursor.x/y/dx/dy` + 完整 Math。

### 1.2 物理:只在读得出"物理感"的地方用真物理

- **Fall**:逐 tick 欧拉积分 `vx -= vx*0.05; vy -= vy*0.1 + 2(gravity)`,
  亚像素余量累积;位移按 `max(|dx|,|dy|)` 细分做**扫掠碰撞**(快速下落
  不会穿过任务栏,还向上探 80px 应对窗口移动)。落地/贴墙即结束,
  由外层 Sequence 的 Select 决定弹跳还是抓墙。
- **Dragged(拖拽手感的核心)**:锚点钉在光标下方 ~120px("拎后颈"),
  一个阻尼弹簧追踪虚拟脚位:`footDx = (footDx + (cursorX-footX)*0.1)*0.8`,
  `FootX` 发布进变量表,`Pinched` 动画按 FootX 相对光标的偏移选 7 张
  倾斜帧 —— 身体在你手下摆动。挣扎机制:静止 10s(250 tick)后按几何
  分布逐 tick 90% 概率续命,最终播挣扎动画 `LostGroundException` 挣脱。
- **Thrown**:释放时把**平滑后的光标速度**(`dx=(dx+Δx)/2` 泄漏平均,
  停顿两帧不清零)直接作为 Fall 的初速度。弹跳不是恢复系数,是落地后
  播 2 帧压扁动画 —— 便宜但比真物理更"好看"。
- **Jump 是假的**:恒速沿偏上的目标点走曲线;爬墙/爬天花板就是
  `BorderType="Wall|Ceiling"` 的普通 Move。

### 1.3 窗口即地形("activeIE")

- 前台窗口矩形被抽象成四条 `Border`(FloorCeiling / Wall),和屏幕工作区
  的边**走同一套 `floor()/wall()/ceiling()` 查询**,窗口边优先于屏幕边。
  于是"站在标题栏上"= `floor.isOn(anchor)`,零特判;一切地面行为在窗口上
  免费复用。
- 窗口移动时,`border.move(anchor)` 用逐帧 delta 重映射锚点(水平按比例,
  垂直按位移);修正量超过 80px(或垂直 >20 下/>80 上)就放弃 —— 慢拖
  窗口宠物会跟着走,快甩会把它甩掉。锚点不再在边上 →
  `LostGroundException` → 强制 Fall。这是唯一的"世界变了"中断机制。
- 搬窗口(ThrowIE)是一串组合:跳到窗角 → FallWithIE → WalkWithIE
  (每步同步移动窗口,每 tick 校验还抓着)→ ThrowIE(抛物线甩出屏幕)。
  有全局开关;`restoreWindows()` 能把甩飞的窗口捞回来。
- macOS 实现的现实:AX API 只能拿**前台 app 焦点窗口**,拿不到标题,
  Dock 高度是写死的 100px。(Mimo 可以做得更好,见 §4.5。)

### 1.4 环境模型

`Area`(带逐帧 delta 的矩形:每屏、每工作区、activeIE)+ `Border` 接口
(`isOn(point)` / `move(point)`)+ `ComplexArea`(多屏集合)+ `Location`
(平滑 dx/dy 的光标)。坐标是全局桌面坐标,**anchor = 脚底接地点**。
多屏:工作区按锚点所在屏缓存,相邻屏间的"缝边"跳过判定,宠物能走过
两台显示器而不是撞隐形墙。

### 1.5 多实例与互动

单线程 Manager 以同一 tick 驱动所有 mascot(作者注:异步会把窗口交互
搞乱)。`Breed` 在动画倒数第二帧生克隆(`#{mascot.totalCount < 50}` 限流);
`Transform` 换形象;`SelfDestruct` 消失。-ee 的 **affordance 系统**:action
可携带 `Affordance="Cuddle"`,只在该 action 运行期间广播;另一只跑
`ScanMove` 向 Manager 查询广播者、走过去、到达时**同时设置双方的
behavior**(握手),`Interact` 播同步动画并每 tick 校验两锚点仍重叠。
配对行为约定 `Frequency="0" Hidden="true"`。

### 1.6 资源包格式

`img/Pack/shime1..N.png`(128² 透明 PNG,画朝左,lookRight 自动镜像)+
`conf/*.xml` + 可选 `sound/`。每帧 `Pose`:`Image`、`ImageAnchor`(图内
对齐到锚点的像素,地面姿势 = 底部中心,天花板姿势 = 顶部)、
**`Velocity="dx,dy"`(该帧显示期间每 tick 施加给锚点)**、`Duration`(tick)。
一个 Action 可挂多个带条件的 `<Animation>`,每 tick 选第一个条件为真的
(Pinched 按 FootX 选倾斜帧、爬墙按方向选上/下循环就是这么做的)。
帧序号 = `经过时间 % 总时长`,没有独立的动画播放器。
-ee 的 **Hotspot**:动画内的可点击区域(矩形/椭圆,精灵局部坐标,随镜像
翻转),点击触发指定 behavior,按住不放可持续(摸头 = hold-and-rub)。

### 1.7 主循环与打断模型

- **40ms = 25fps** 单 tick 线程;每 tick:环境快照 → 队列化的增删 →
  所有 mascot `tick()`(逻辑)→ 所有 `apply()`(渲染),逻辑渲染两相分离。
- 打断是**行为替换,不是栈**:按下 → `Dragged`(除非 `Draggable="false"`
  或 hotspot 认领);松手 → `Thrown`;失去地面 → `Fall`;无可选行为或
  跑出屏幕 → 传送到屏幕上方随机 x 落下(经典"从天而降"重置,自愈且
  符合世界观)。
- Action 的"结束"定义:Stay 到时/失条件、Move 到点、Animate 播完一轮、
  Fall 落地、Dragged 挣脱、Sequence 子项耗尽、Select 选中项耗尽。

### 1.8 为什么手感好(可移植的设计决策)

1. 加权 + 环境门控的 idle 多样性;随机 Duration 消灭节拍器感。
2. NextBehaviorList 造出连贯的"小场景"而非均匀乱抽。
3. 一条冷酷的打断规则 —— 宠物永远不无视你的手。
4. **运动烘焙进美术**(每帧 Velocity):零滑步,作者不写代码就能调步态。
5. 真物理只给坠落/抛掷;跳跃弧线、落地弹跳全是便宜的假动作。
6. 拖拽弹簧 + 挣脱循环:它"活着",不是你的所有物。
7. 窗口降维成四条边,插进统一地形抽象,一切行为免费复用。
8. 所有失败路径收敛到"从天上掉下来"——自愈、成立于世界观内。
9. 25fps 锁步让多实例同步和窗口交互变得平凡。
10. 数据驱动到骨子里:15 个动词 + 5 个组合子 + 表达式 = 整个社区的创作力。

---

