# Apple Photos → DIY 伴灵 prototype

> THROWAWAY PROTOTYPE — 验证后要么吸收进正式 Studio，要么整个删掉。

## 要回答的问题

Mimo 能否在用户明确点击后，用 PhotoKit 读取最近照片，用 Vision 在本机
找到人像并整理成「可能是同一人」的候选组，然后在用户确认后，把最好的
3–4 张人像直接交给现有 DIY 参考集。

## 隐私与能力边界

- 只有点击「扫描最近照片」才请求 Photos 权限。
- 默认不下载 iCloud 原图；需要时由用户单独勾选。
- 脸部检测、质量排序与候选分组都在本机。
- 不读取「人物与宠物」名称，不声称识别了身份。
- 选定前不进入 DIY，也不会调用 OpenAI。
- 交接用的人像裁剪只写到临时目录，10 分钟后删除。

## 运行

```bash
./mac/prototypes/apple-photos-people/run.sh
```

这会打开 bundle ID 独立的 `Mimo Photos Prototype`，不会取代正在运行的 Mimo。
正式 Mimo 的菜单中也保留了「实验：从照片找主角…」入口。

## 当前判定

见 [NOTES.md](NOTES.md)。
