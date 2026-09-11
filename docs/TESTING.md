# 测试与验证边界

所有测试使用合成数据；不需要真实漫画、导出数据库或个人凭据。

## 静态发布检查与纯规则测试

```sh
sh scripts/check.sh
```

脚本执行允许文件清单与常见隐私风险检查，再编译运行 Swift 纯规则测试。它需要 macOS 与 Swift 工具链。启发式扫描不是秘密泄露或法律合规的绝对保证。

安卓纯 Java 检查另用 `sh scripts/check-android.sh`，需要 JDK 17 以及通过 Gradle 解析的 NanoHTTPD / ZXing JAR。脚本从环境指定的 Gradle 缓存读取，不携带个人路径。PairingEndpointCheck 会绑定本机回环地址临时端口，测试结束关闭；不是手机网络测试。

## iOS 界面测试

使用独立、无真实配对的模拟器。选择共享 `ReaderInteractionChecks` scheme，再选择已安装的 iOS 模拟器运行测试。合成模式会修改模拟器内本应用的测试偏好，不能在个人数据环境运行。相机页的合成界面不等同真实 VisionKit 扫码验证。

示例（自行替换 SIMULATOR_UDID，不要把设备 ID 提交到仓库）：

```sh
xcodebuild -project ios/LocalShelf.xcodeproj -scheme ReaderInteractionChecks \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath build/simulator -parallel-testing-enabled NO test
```

模拟器 Keychain 测试需要正常 Xcode ad-hoc 签名，不应设置 `CODE_SIGNING_ALLOWED=NO`。界面用例不代表实际屏幕帧率、动画 120 Hz 或真实 Wi-Fi 延迟。

## 仍需实机验证

- 安卓通知、目录授权、锁屏长传输与厂商电池策略。
- iPhone 真实扫码、低内存、断网恢复与手势体验。
- NAS 实际部署与协议互通；本仓库不包含 NAS 服务。
- 本次公开包的具体构建／检查结果见 `RELEASE_REVIEW.md`；没有运行的检查不宣称已通过。
