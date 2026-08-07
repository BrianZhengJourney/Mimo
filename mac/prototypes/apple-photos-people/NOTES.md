# Prototype verdict

## 已知

- PhotoKit 可读取授权范围内的 asset 与缩略图。
- Vision 可找脸、评估 capture quality，并为图像生成 feature print。
- 现代 Photos 「人物与宠物」的命名与分组没有公开成可直接消费的
  PhotoKit API；本 prototype 只能做可回看、可拒绝的本地候选分组。

## 待实机回答

- 300 张最近照片的扫描时间是否可接受？
- generic image feature print 对面部裁剪的分组准确度是否足够支持「候选」？
- 用 3–4 张同一人的局部人像交给当前 reference preprocessor，是否比手动挑图更稳？
- 是否应只支持用户手动选的 PhotosPicker 资产，而不是全库扫描？

## 去留规则

- 如果候选分组明显出错：保留 Photos 选图，删除自动分组。
- 如果分组可用：把 scanner 收紧成 Studio 内的可选入口，再补测试和持久化边界。
