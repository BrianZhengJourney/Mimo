> 伴灵模式计划 · 模块文档 — [索引与阅读顺序](README.md)
> 章节编号(§0–§8)沿用拆分前的全局编号,跨文件引用见索引的对照表。

## 7. 待核实的事实断言

初稿中有两处断言在本轮源码复核中**未能独立验证**,落地前需实测:

1. **`CGWindowListCopyWindowInfo` 取窗口 bounds 无需任何权限**(§4.5)。
   这是 P4 是否值得做的决定性变量。若需 Screen Recording 权限,
   是显著的用户摩擦点。
2. **引擎硬性要求四个 behavior:`Fall` / `Dragged` / `Thrown` / `ChaseMouse`**
   (§1.1)。源码中确认了:`Fall` 是选择器兜底路径
   (`Configuration.buildNextBehavior` 末尾 `buildBehavior(BEHAVIORNAME_FALL)`),
   `Dragged` / `Thrown` 由 `UserBehavior` 的鼠标事件路径引用。
   **`ChaseMouse` 作为硬性要求未获验证。**

### 生成 provider 侧的未确认项(2026-07-18 核查)

§4.8–§4.10 的事实基本都核实到了官方文档,以下几项**没有**:

3. **Gemini 各档位的"角色参考"数量上限** —— 同一个官方页面两次抓取给出了
   互相矛盾的分配表(一说 Flash 5 个角色、一说 Flash 10 物体 + 4 角色)。
   **落地前需实测。** 可靠的部分:总参考 ≤14,且角色参考是独立类型。
4. **Gemini 是否支持 alpha** —— Google 官方两个方向都没表态;社区一致报告
   无原生 alpha。我们走 flat matte 抠图,所以不阻塞,但别假设。
5. **OpenAI 的 gpt-image-2 发布说明** —— `openai.com` 该页返回 403,
   所有"发布于 2026-04-21""face-preserving reference lock"
   "一次出 8 张一致图像"的说法均为二手且未证实。
   特别注意最后一条被描述为 **ChatGPT 产品功能而非 API 能力**,
   **不要按它做设计**。
6. **arena.ai 的 multi-image-edit 榜单** —— 这是比 image-edit 榜更贴近
   精灵表场景的代理指标,但原始来源抓取失败(402),两个二手来源
   互相矛盾且与已核实的 image-edit 榜矛盾。**只信 §4.9 里那个已核实的快照。**
7. **Apple Vision feature print 的距离取值范围,以及 iOS 16→17 底层模型
   变更导致阈值失效** —— 均为开发者报告,Apple 文档未明说。
   但风险不对称,§4.10 要求显式 pin `revision` 的结论不受影响。
8. **未找到任何隔离测量"跨次生成角色身份保持"的公开基准。**
   这正是 §4.9 主张用自己的数据跑 A/B 的原因。
9. **精灵表的 prompt 模式、后处理对齐工具链、以及专用替代方案
   (PixelLab / Scenario / Layer.ai / ControlNet / IP-Adapter / LoRA)
   本轮基本未调研。** 唯一核实的是绿幕抠图技术(§4.9 策略 4)。
   若 P3 的一致性通过率不理想,这里值得单独做一轮调研 —— 但注意
   LoRA/ControlNet 路线需要**每角色训练步骤**,对"每个用户一只新伴灵"
   的消费级 app 是完全不同的成本与延迟模型。

另有一处**源码与文档互相矛盾**,已在 §4.4 记录:`Mascot.xsd:705-713` 称
pose `Velocity` 朝右时不翻转,而 `animation/Pose.java:8` 明确
`isLookRight() ? -dx : dx`。**以代码为准。**

### 本轮源码复核的其他增量(初稿未覆盖或表述不同)

- **`NextBehaviorList Add` 是唯一的门控机制,且语义是二元的**:
  `Add="false"` = 排除全局池(**硬链**,一个"计划");
  `Add="true"` = 与全局池**并集**、同权重尺度竞争(**软推**,一次"联想")。
  两种模式混用才产生"意图感"。
- **`Frequency="0"` ≠ 禁用**,而是"从环境抽奖池移除、只能被显式引用到达";
  `Hidden="true"` 与之**正交**(仅影响右键菜单显示)。
- **自引用高权重 = 免费的几何驻留分布**:`SitAndFaceMouse` 自链
  `Frequency=100` 对两个 `Frequency=1` 的替代,约 98% 续杯 —— 两行配置
  写出自然驻留时间,不需要显式定时器。
- **`isOn` 是单轴精确整数相等**(`getY() == location.y`)。这解释了
  `Fall` 里 `-80..0` 着陆探针为何存在(防穿透 —— 相等判定下快速下落会直接
  穿过所有表面,80px 是穿透预算),以及走过墙角为何要手写 `Offset Y="-64"`。
  libshijima 已改为 `fabs(p.y - y) < 1.0` + 全 double —— **抄这个修复,
  不要抄原版**。
- **libshijima 的已知语义退化**:`scripting/condition.cc:8-13` 把 `$` 和 `#`
  当同一件事处理,丢掉了"求值一次"的优化。别重蹈。
- **`BornTransient` 走独立开关**:短命道具(被扔出的东西)可以允许,
  而真正的克隆关闭。这个拆分值得抄。
- **未取得 Yuki Yamada 的原始 Group Finity 源码。** 所有关于"原版"的断言
  基于 fork 中保留的日文标签名、`com.group_finity.mascot` 包名、
  `@author Yuki Yamada` 注解推断。以下**可能是 fork 特有而非上游**:
  Nashorn class filter、`Hotspot`、`Toggleable`、`Transform`/`SelfDestruct`/
  `Mute` 动作、两相 tick/apply 拆分、以及 XSD 本身。
  `github.com/Kilkakon/Shimeji-ee` 与 `github.com/nkrapivin/shimeji-desktop`
  均 404;`DalekCraft2/Shimeji-Desktop` 与 `gil/shimeji-ee` 是 1.0.13 源码的
  维护镜像。

---

## 附:源码参照

- Shimeji-Desktop(本文主要依据,已克隆细读):
  <https://github.com/DalekCraft2/Shimeji-Desktop> —
  `Manager.java`(40ms tick)、`behavior/UserBehavior.java`(打断)、
  `action/{Fall,Dragged,Jump,Move,Breed,ScanMove,Interact}.java`、
  `environment/{Area,Border,FloorCeiling,Wall,MascotEnvironment}.java`、
  `config/{BehaviorBuilder,Configuration}.java`、`script/Variable.java`
  (`${}`/`#{}`)、`conf/{actions,behaviors}.xml`。
  另:`conf/Mascot.xsd`(规范 XSD,含全部 action 参数与默认值)、
  `animation/Pose.java`(velocity 翻转)、`animation/Animation.java`
  (帧号 = 时间 % 总时长)、`image/ImagePairs.java`(镜像锚点
  `width - anchorX`、premultiply 时机)。
- libshijima(C++ 重实现,环境模型极简参考;**注意其 `$`/`#` 语义退化**):
  <https://github.com/pixelomer/libshijima> — `shijima/translator.cc`
  (日文↔英文标签全映射)、`environment.hpp`(容差判定 + double 几何)、
  `scripting/condition.cc`。
- Shijima-Qt:<https://github.com/pixelomer/Shijima-Qt>
- libshimejifinder(社区资源包归一化,`.mascot` bundle 形态参考):
  <https://github.com/pixelomer/libshimejifinder>
- Shimeji-ee 文档(affordance/hotspot):<https://kilkakon.com/shimeji/>
  (注:`github.com/Kilkakon/Shimeji-ee` 不存在,Kilkakon 在 GitHub 之外分发)
- Mimo 现状:`mac/main.swift`(panel/热区/拖拽/victory walk)、
  `mac/overlay.html`(Fam 状态机/focus 引擎/Mascot 渲染器/pointer 交互)、
  `mac/custom_pet.swift`(raster sheet 契约)、`mac/panel_geometry.swift`、
  `docs/diy-strategy.md`(两 lane 策略,本计划的 §4.6 与其对齐)。
