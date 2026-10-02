# 来源和第三方许可

## 自有代码

根目录 MIT 适用于项目自有代码、配置和合成测试。开发中使用了 AI 辅助；公开整理没有复制 EhViewer 的登录或下载引擎，不是其官方移植。版权与来源检查基于现有代码、依赖和开发记录，不是互联网全量相似性审计，也不是法律担保。

## 实际依赖

| 组件 | 依赖 | 许可与分发说明 |
|---|---|---|
| Android 阅读端 | AndroidX RecyclerView 1.4.0、ViewPager2 1.1.0 及解析出的 AndroidX、Kotlin、协程、注解、ListenableFuture 依赖 | Apache-2.0；完整许可与依赖通知保留在 [assets/licenses](android-reader/app/src/main/assets/licenses/) 中，构建时不应删除依赖元数据 |
| NAS Reader | Pillow 12.3.0 | MIT-CMU；[Pillow 许可全文及说明](nas-reader/THIRD_PARTY_NOTICES.md)。分发镜像/轮子时保留对应平台 wheel 内全部 codec 许可，不能仅保留本项目 MIT |
| NAS Sync | Python 标准库和外部 OpenSSL 命令 | 本仓库不分发 Python/OpenSSL 二进制；构建容器时保留基础镜像与软件包自身许可 |
| Windows 上传端 | .NET 8、WPF、Windows API | 本仓库不分发 .NET 运行时；自行发布自包含包时保留实际运行时的 LICENSE 和 THIRD-PARTY-NOTICES |
| iOS、macOS 续签助手 | SwiftUI、UIKit/AppKit、Foundation、ImageIO、Security 等 Apple 系统框架及 Xcode | 系统/开发工具未随源码分发，受 Apple 自身协议约束，未重新许可为 MIT |
| Android 同步端、Web 网关 | Android 平台 API / Python 标准库 | 不捆绑额外第三方运行时库；SDK、Gradle、JDK 和基础运行时不属于本项目自有代码 |

依赖解析信息见 Android 工程 build.gradle 与随包 NOTICE。版本和新增依赖应在每次发布时复核。原桥接端的 NanoHTTPD/ZXing 不属于当前八组件依赖；旧版本的声明保留在 Git 历史，不代表新阅读端仍使用它们。

本次保留一份独立实现的有界队列合成实验供测试，但没有发布 pyvips/libvips 实验镜像或相关二进制。NAS 生产 Dockerfile 仍只使用 Pillow。

## 参考而非运行时依赖

开发记录提到 Nuke、Kingfisher、SDWebImage、Texture、PhotoBrowser 等开源项目的调度、缓存和交互设计，以及 EhViewer 离线目录/导出表结构。致谢不替代许可证；如果后续实际引入或改编其他项目代码，必须重新核对其许可，不能因为曾列为设计参考就省略要求。

## 资源

- EH 字母图标为独立 AI 辅助生成资源，不使用个人头像或官方 EhViewer 图标。macOS 的「续签」图标由仓库中的原生绘图脚本生成。在贡献者有权授予的范围内按 MIT 提供，不保证排他性版权或商标权。
- 测试媒体由程序生成，不含真实漫画。界面中的系统符号通过系统 API 使用，没有导出 SF Symbols 字体或图形给其他平台。
- 用户导入的图片与书库元数据属于各自权利人，不由本项目许可覆盖。

主要依据：[Pillow 官方项目](https://github.com/python-pillow/Pillow)、[AndroidX 源码](https://android.googlesource.com/platform/frameworks/support/)、[.NET 运行时](https://github.com/dotnet/runtime)。
