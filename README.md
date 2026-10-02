# LocalShelf

把自己的离线图片书库放在 NAS，在 iPhone、Android 或浏览器上阅读。

LocalShelf 是面向可信私人局域网的开源工具套件，不提供漫画内容、网站登录、资源搜索或在线下载。排序还原 EhViewer 已下载漫画的下载顺序，支持 EhViewer 导出的下载列表；顺序冲突或信息缺失时会提示确认，不冒充已核实。

## 当前源码

| 组件 | 版本 | 目录 |
|---|---|---|
| iOS 原生阅读端 | 0.4.38（65） | [ios](ios/) |
| Android 原生阅读端 | 0.1.2（3） | [android-reader](android-reader/) |
| NAS 阅读服务 | 0.1.18-dev | [nas-reader](nas-reader/) |
| Android 同步上传端 | 0.4.10（16） | [android-sync](android-sync/) |
| NAS 同步接收服务 | 0.4.5-dev | [nas-sync](nas-sync/) |
| Windows 手动上传端 | 0.1.0 | [windows-uploader](windows-uploader/) |
| 网页阅读网关 | 0.1.1-dev | [web](web/) |
| macOS 续签助手 | 0.1.2（3），公开配置版 | [macos-signer](macos-signer/) |

旧版本的 `android/` 是只读桥接服务，**不是**现在的安卓阅读端或上传端。本版按功能拆分目录，旧桥接实现仍可在 Git 历史中查看。iOS 中保留旧桥接协议兼容能力，默认推荐 NAS 工作流。

## 阅读与导入

- iOS 使用 SwiftUI/UIKit；Android 使用 RecyclerView/ViewPager2。深色书库、2/3 列封面、每页 50–500 本、当前页快速定位、封面页数角标、继续阅读及原位置跳转。
- 左右滑动翻页、页码点击/拖动跳转、GIF/动态 WebP、相邻页预取、有界内存和磁盘缓存。超大或损坏动图可能回退静态预览；不承诺固定帧率或任意动图瞬时播放。
- 长按查看同作者、同系列。依据标题中的署名和命名线索匹配，宽松候选会标注，不是权威标签系统或自动确认作者身份。
- Eh 同步库保留导入清单的列表顺序与已确认的页码。日常同步可复用已确认回执，支持新增、重排和内容更新；不删除手机源文件。元数据全部不变的静默改写仍需完整校验发现。
- Windows 工具上传到独立手动书库，图片按 **Windows 原始修改日期递增** 排列，同时间以自然文件名打破平局。不会混进 Eh 同步清单。
- 阅读端有手动触发的连接诊断和可复制脱敏摘要。NAS 分开判断“进程运行”和“书库就绪”；健康检查不自动重启服务，也不是图片完整性检查。

## 典型配置

1. 在 NAS 上部署 `nas-sync`，Android 同步端选择下载目录、导入自己的最新 `.db`，再导入 NAS 生成的配对文件。配对文件包含访问凭据，不要分享。
2. 部署 `nas-reader`，把同步数据只读挂载为 `/source`，阅读服务身份独立保存在 `/state`。设置自己的阅读密码，不要使用 NAS 管理员密码。
3. iOS 或 Android 阅读端填写自己的 NAS 阅读地址和密码。初次成功后保存随机阅读凭据，不必每次重新配对。
4. 需要手动导入时，启用 Reader 的 `compose.manual.yaml` 和独立 `/manual` 目录，用 Windows 上传工具导入，在阅读端顶部切换书库。
5. 网页端是独立网关，按需部署。macOS 续签助手也是可选组件，不需要安装它才能编译 iOS。

所有示例地址都是示意值，必须自行设置。仓库不包含开发者的 NAS 配置、MAC、口令、Apple ID、签名材料或书库数据。**不要把 Reader/Sync 端口直接转发到公网。** HTTP 阅读只适合可信局域网；外部访问需要自行正确配置 HTTPS、认证和网络边界，不提供任何厂商穿透的可用性承诺。

## 构建

见 [BUILDING.md](BUILDING.md)，包含各组件的工具版本、命令和安全测试入口。公开源码不含 SDK、运行时、私钥、证书、已签名 IPA/APK 或预填的自用配置。Android Release 默认不签名；iOS 需要自己的开发团队。

公开版验证范围与限制见 [docs/VALIDATION.md](docs/VALIDATION.md)。对源码的测试不等于对使用者硬件、整个书库、外网或 App Store 审核的保证。

## 隐私和许可

项目自有代码采用 [MIT](LICENSE)，版权署名 zhanshaoqian。第三方依赖保留各自许可，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。项目使用 AI 编程辅助；独立 EH 字母图标不是官方 EhViewer 图标，项目与 EhViewer、Apple 或 NAS 厂商没有隶属关系。

请只处理你有权保存、传输和阅读的内容；仓库不附带真实漫画或用户清单。发布问题时不要上传 `.db`、配对文件、证书、NAS 地址或原始日志。详见 [PRIVACY.md](PRIVACY.md)、[SECURITY.md](SECURITY.md) 和 [贡献说明](CONTRIBUTING.md)。
