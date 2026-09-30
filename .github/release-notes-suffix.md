## ⚠️ 这个包要你在本机签名才能用

CI 拿不到你的 Apple 开发者证书, 所以这里的 `.app` 是**未签名**的 (构建显式 `--no-sign`)。
未签名的 App 从浏览器下载后带 quarantine 标记, 双击会被 Gatekeeper 拦, 报
「无法打开, 因为无法验证开发者」—— 没有任何可归因的错误信息。

装法 (资产都在同一个目录, 换 `arm64` / `x86_64` 成你机器的架构):

```bash
shasum -a 256 -c checksums.txt                              # 先验完整性
bash MangoX-<ver>-install.sh MangoX-<ver>-<arch>.zip
```

它会: 解包 → 清隔离属性 → ad-hoc 重签 → 校验 → 启动。脚本用的是绝对路径
`/usr/bin/xattr` (PATH 里的 `xattr` 可能被 pyenv shim 之类抢占, 那个不认 `-r`,
一跑就 `option -r not recognized`)。

手动等价于 (`.app` 已解到当前目录):

```bash
/usr/bin/xattr -cr MangoX.app
codesign --force --sign - --timestamp=none --entitlements mangox.entitlements MangoX.app
open MangoX.app
```

ad-hoc 签名只解除 Gatekeeper 的发布者校验, 不做身份认证、不带时间戳、不走公证。
**适合自己和同事在本机用; 要分发给陌生用户, 必须上 Apple Developer 证书 + notarization。**

## 运行还需要 (App 不自带这些)

- **[pi CLI](https://github.com/earendil-works/pi) 已装且在 PATH** —— MangoX 只是推理引擎的
  GUI, 缺 pi 时 App 会显示「引擎不可用」横幅, 不会假装在回复
- **node** —— pi 是 node 脚本
- pi 侧配好模型 provider 与 API key (App 内: 设置 → 模型 管理)
- macOS 14.8+
