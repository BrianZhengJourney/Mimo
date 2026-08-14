# Prototype verdict

## 已知

- PhotoKit 可读取授权范围内的 asset 与缩略图。
- Vision 可找脸、评估 capture quality，并为图像生成 feature print。
- 现代 Photos 「人物与宠物」的命名与分组没有公开成可直接消费的
  PhotoKit API；本 prototype 只能做可回看、可拒绝的本地候选分组。
- PhotoKit 公开了收藏、自拍、最近添加等 Smart Album，以及 asset 的日期、
  收藏和地点元数据；这些可以缩小扫描范围并形成不涉及身份的卡片小结。
- `albumSyncedFaces` 只代表从旧 iPhoto 同步的 Faces group，不等同于现代
  Photos 的「人物与宠物」，不能用它冒充人物 API。

## 当前 pipeline（v3 Core ML prototype）

1. **PhotoKit 缩小范围**：最近、收藏、自拍、人像模式；排除截图，连拍只取一张，
   iCloud 缩略图默认关闭。
2. **Vision 本地取证**：每图最多四张脸；用 capture quality 淘汰模糊小脸，
   取 5 个 landmark，将人脸仿射对齐成 112×112。
3. **AdaFace IR101 / Core ML**：只在本机生成 512 维身份向量；原始向量范数
   作为图像质量信号，不保存姓名或 Photos 「人物与宠物」数据。
4. **混合约束聚类**：IR101 先组成稳定 identity core；KP-RPE 只复核互为唯一
   最近且有明确领先幅度的组。频繁同照片出现仍是 must-not-link，少量重复检测
   不再永久阻断正确合并。
5. **两步可回看 UI**：人物列表只显示目标脸、编号与照片数；点「选择样子」后
   才显示照片网格，默认推荐 6 张，可切换最近外观或手动选 2–8 张。
6. **失败回退**：系统 PhotosPicker 可有序选择 1–8 张图，不需要依赖自动聚类。
7. **参考图选择**：44 张等候选只作为本机可选库，不会全部交给生成；最终只传
   用户确认的 2–8 张临时裁剪。

## 2026-08-11 真实 Photos A/B

| 模型（平衡档） | 常出现的人 | 单张 | 最大组 | 平均推理 | Core ML 大小 |
|---|---:|---:|---:|---:|---:|
| Vision Feature Print | 20 | 34 | 27 | 未单独计时 | 系统内置 |
| **AdaFace IR101** | **3** | **2** | 65 | **12.45 ms/脸** | **125 MB** |
| ViT Base KP-RPE | 3 | 0 | 81 | 34.21 ms/脸 | 220 MB |

样本为最近 600 张 asset：126 张可用面孔，73 张缩略图当时不在本机。
IR101 的 65 / 42 / 17 三个主组经 UI 核对分别是三位不同的人；
KP-RPE 虽然没有单张，但组大小重排为 81 / 33 / 12，且从精准到平衡档的分组
变化更大。所以本轮选 **IR101 + 平衡档**，不以「0 单张」当成更准。

后续真实照片暴露了帽子、侧脸拆组；当前默认包改为 IR101 主分组 + KP-RPE
二次复核。KP-RPE 不独立决定分组，避免用更激进模型换来跨人物误合并。

### 参考图选择 verdict（2026-08-14）

比较了卡片内展开、独立选择页、全屏向导三种结构。选择 **独立选择页**：人物
列表保持短而可扫读；只有点开一个人时才展开 44 张等候选。默认「米墨推荐」
6 张，「最近的样子」会重新选最近 6 张，任何手动增删进入「自己挑」。少于
2 张不能继续，最多 8 张。这样既让用户决定年龄、发型、配饰的参考状态，也
不把识别/质量诊断暴露成产品信息。

### 正式入口回归（2026-08-12）

曾出现正式 Mimo 给出 18 人、而 model lab 只有 3–6 人的回归。根因不是阈值：
`run.sh` 会把 IR101 放入独立 prototype bundle，普通 `build.sh` 却没有；运行时
又在模型缺失时静默回退到 Vision，所以界面看似选了 IR101，实际还在跑旧聚类。

现在 `build.sh` 会将本地转换的 IR101 打入普通 Mimo；模型缺失时扫描直接停止并
显示说明，不再回退 Vision。重建后需完全重启 Mimo，因为旧进程会缓存模型加载结果。

不建议把脸发给云端 LLM，也不建议用 Foundation Models 猜“是不是同一人”：
那既不是专用身份模型，也会让产品边界与隐私说明变得含糊。

## 上线前还要回答

- 600 张最近照片的扫描时间是否可接受？收藏/自拍扩到 900 张是否太慢？
- 三档阈值在真实照片中的误拆 / 误合并分布；默认「平衡」是否合适？
- 默认 6 张、允许 2–8 张的参考集，在不同年龄/发型跨度下是否稳定？
- 当前权重及 WebFace12M 训练数据只适合研究验证；正式发布前需重新审核模型与数据许可，
  或替换为拥有可商用链路的等价模型。

## 去留规则

- 如果候选分组明显出错：保留 Photos 选图，删除自动分组。
- 如果分组可用：把 scanner 收紧成 Studio 内的可选入口，再补测试和持久化边界。

## Apple 官方资料（2026-08-10 核对）

- [PhotoKit](https://developer.apple.com/documentation/photokit)：授权范围内的 assets、collections 与 iCloud Photos。
- [PHAssetCollectionSubtype](https://developer.apple.com/documentation/photos/phassetcollectionsubtype)：公开 Smart Album 列表；没有现代 People & Pets subtype。
- [Self Portraits](https://developer.apple.com/documentation/photos/phassetcollectionsubtype/smartalbumselfportraits)：系统自拍相册是前置摄像头照片，不等于人物识别。
- [PhotosUI](https://developer.apple.com/documentation/photosui/)：系统选图器可作为自动分组失败时的隐私友好回退。
- [PHPickerViewController](https://developer.apple.com/documentation/photosui/phpickerviewcontroller)：macOS 原生系统选图控制器。
- [Face Capture Quality](https://developer.apple.com/documentation/vision/vndetectfacecapturequalityrequest)：只用于清晰、居中等质量排序。
- [VNFaceObservation](https://developer.apple.com/documentation/vision/vnfaceobservation)：公开 roll / yaw / pitch 与 landmarks。
- [Image Feature Print](https://developer.apple.com/documentation/vision/generateimagefeatureprintrequest)：通用图像特征，不应表述成 Apple 人脸身份识别。
- [Core ML](https://developer.apple.com/documentation/coreml)：可在设备端运行自定义模型，不需上传照片。
