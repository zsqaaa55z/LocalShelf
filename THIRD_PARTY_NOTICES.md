# 来源、依赖与资源说明

## 本次发布范围

Swift 源码、测试、工程配置和项目文档按根目录 MIT 许可提供。开发过程使用了 AI 编程与图像生成辅助。代码来源判断基于当前工程及开发记录，并非对互联网全部源码进行过相似性检索，也不构成法律意见或第三方权利保证。

检查当前 iOS 工程未发现 Swift Package、CocoaPods、Carthage、第三方源码目录或预编译第三方库。它使用 Apple 的 SwiftUI、UIKit、Foundation、ImageIO、VisionKit、AVFoundation、Security、CryptoKit、UniformTypeIdentifiers 等系统框架；测试使用 XCTest。这些框架未在仓库内分发，受 Apple 自身协议约束，不由本项目重新许可。

## 安卓实际运行时依赖

| 依赖 | 版本 | 许可 | 随包声明 |
|---|---|---|---|
| org.nanohttpd:nanohttpd | 2.3.1 | BSD-3-Clause | [实际 JAR 的完整许可](android/app/src/main/assets/licenses/NanoHTTPD-LICENSE.txt) |
| com.google.zxing:core | 3.5.3 | Apache-2.0 | [Apache 2.0 全文](android/app/src/main/assets/licenses/Apache-2.0.txt)、[ZXing 上游 NOTICE](android/app/src/main/assets/licenses/ZXing-NOTICE.txt) |

两项均为未修改的 Maven 依赖，没有把它们改成 MIT。完整声明在安卓 assets 中，并有应用内查看入口，便于二进制分发时保留。NanoHTTPD 以实际 Maven JAR 的 `LICENSE.txt` 为准，而非用不同版权行的仓库根文件替换。ZXing 上游根 NOTICE 保守完整保留，其中对其他模块的归属不表示本应用引入了那些模块；没有引入 ZXing javase 或 jai-imageio。详见 [依赖说明](android/app/src/main/assets/licenses/DEPENDENCIES.txt)。

Android SDK、JDK、Gradle 和构建插件为外部构建工具，未随源码打包；使用和另行分发应遵守各自许可。安卓导入器通过 Android SQLite API 查询用户选择的导出数据，未包含上游 ORM、网站登录或下载引擎。

## 设计参考，不是随包分发的依赖

根据开发记录，以下项目用于了解设计机制，没有将其源文件、二进制或视觉资源收入本发布包：

- [Nuke](https://github.com/kean/Nuke)：加载调度、请求合并、分层预取与节流。
- [Kingfisher](https://github.com/onevcat/Kingfisher)：处理后缩略图与分层缓存。
- [SDWebImage](https://github.com/SDWebImage/SDWebImage)：动图帧缓冲。
- [PhotoBrowser](https://github.com/JiongXing/PhotoBrowser)：UIKit 分页与视图复用。
- [Texture](https://github.com/TextureGroup/Texture)：可见、准备与预取范围的区分。
- [FDFullscreenPopGesture](https://github.com/forkingdog/FDFullscreenPopGesture) 与 [Hero](https://github.com/HeroTransitions/Hero)：边缘热区、位移与速度判定；未采用私有导航处理方法。
- [TrackableScrollView](https://github.com/maxnatchanon/trackable-scroll-view)：滚动位置与界面状态同步。
- [JTSScrollIndicator](https://cocoapods.org/pods/JTSScrollIndicator)：细滚动指示条的视觉参考。
- [EhViewer_CN_SXJ](https://github.com/xiaojieonly/Ehviewer_CN_SXJ)：阅读体验及离线目录协议研究；本发布包不是该项目的 iOS 源码移植，也不含其代码、图标或内容资源。

致谢不是替代许可证的手段。若后续实际复制、翻译、改编或引入第三方实现，应先核对对应版本许可证，保留要求的声明，并履行可能存在的源码公开义务。不能仅凭没有依赖管理文件就认定不存在衍生代码。

## 图标、测试图片与系统符号

- 当前 `eh` 融合字母 PNG 是 AI 生成的新图标，未使用个人头像、漫画封面或官方 EhViewer 图标作为输入。在贡献者有权授予的范围内，随项目按 MIT 提供；不保证生成图像拥有可独占版权，也未做商标注册／相似商标检索。
- 模拟界面中的图片为程序生成的色块、文字及小型多帧测试数据，没有附带真实漫画。
- 代码通过系统 API 使用 SF Symbols；没有导出其字体或图形到仓库。Apple 系统符号不因本项目 MIT 许可而获得独立再许可。
- LocalShelf 与 `eh` 字样不表示获得 EhViewer 或任何内容平台的授权或背书。
