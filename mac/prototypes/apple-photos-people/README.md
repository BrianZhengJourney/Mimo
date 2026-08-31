# Apple Photos → DIY 伴灵 prototype

> 2026-08-31 边界：这是独立诊断 prototype，不是正式产品入口。实际 Photos / DIY Studio 在 `mac/settings.html`；prototype 只用于模型 A/B、权限和候选 UI 的隔离验证。

## 要回答的问题

Mimo 能否在用户明确点击后，用 PhotoKit 读取最近照片、收藏、自拍或人像相册，
用 Vision 在本机找到人像并整理成「可能是同一人」的候选组，然后在用户
确认后，让用户从本地候选池挑选 2–8 张最像自己的参考图，再交给现有 DIY 参考集。

## 隐私与能力边界

- 只有点击「开始查找」才请求 Photos 权限。
- 默认不下载 iCloud 原图；需要时由用户单独勾选。
- 脸部检测、质量排序与候选分组都在本机。
- 不读取「人物与宠物」名称，不声称识别了身份。
- 同一张照片里的不同脸是强分组边界；跨照片只在双模型都支持时谨慎合并。
- 44 张等完整候选池只留在本机供挑选，不会全部进入生成。
- 选定前不进入 DIY，也不会调用 OpenAI。
- 默认由 Mimo 推荐 6 张，用户可在 2–8 张之间调整；只有确认的裁剪会写入临时目录，10 分钟后删除。
- 「手动选照片」使用系统 PhotosPicker，只交付用户明确选择的 1–8 张图。

## 运行

```bash
./mac/prototypes/apple-photos-people/setup_face_models.sh
./mac/prototypes/apple-photos-people/run.sh
```

首次运行或本地模型损坏时，先执行 setup。模型会保存在
`mac/.local/face-models`（Git 忽略），不会再依赖可能被系统清理的
`/private/tmp`。`build.sh` 也会验证 `coremldata.bin`，拒绝把空的
`.mlmodelc` 目录误装进 App。

这会打开 bundle ID 独立的 `Mimo Photos Prototype`，不会取代正在运行的 Mimo。
正式 Mimo 的菜单中也保留了「实验：从照片找主角…」入口。
默认装载 IR101 + KP-RPE 两个 Core ML 模型，以混合判定减少同一个人被拆成多组。
本地模型存在时，普通 `mac/build.sh` 也会把它放进正式 Mimo bundle；
如果缺失，Photos 身份扫描会明确停止，不会静默退回 Vision。

需要重现 Vision / IR101 / KP-RPE A/B 时：

    ./mac/prototypes/apple-photos-people/run.sh --photos-people-model-lab

不读取真实 Photos 数据的 UI 预览命令：

    ./mac/prototypes/apple-photos-people/run.sh --photos-people-ui-preview

## 这轮 UI

- 默认 600×760 的窄幅纵向窗口，最大宽度 660；原始照片尺寸不会影响窗口。
- 结果改成单列人物行：64px 主图、照片数与一个「选择样子」操作；日期、评分、模型名等诊断信息全部隐藏。
- 只优先展示至少出现两次的人；不可选择的单张线索默认折叠。
- 来源可选最近 600 张、收藏、自拍与人像模式；排除截图并去重连拍。
- 点开人物后进入独立选择页：`米墨推荐 / 最近的样子 / 自己挑`，默认 6 张、最少 2 张、最多 8 张。
- 合并力度、模型名与 A/B 指标不出现在默认界面；它们只在 model lab 中显示。
- 自动分组不理想时，可直接进入系统 PhotosPicker 手动补救。

## 当前判定

见 [NOTES.md](NOTES.md)。
