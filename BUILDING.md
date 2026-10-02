# 构建与本地部署

各组件单独构建。不要在装有真实个人配置的实体机上运行测试包或未经审查的部署脚本。

## iOS

使用 Xcode，打开 `ios/LocalShelf.xcodeproj`，选择 LocalShelf scheme。最低 iOS 17；源码中没有个人开发团队。模拟器可使用 ad-hoc 签名，实体设备需在 Xcode 登录自己的开发者账号并选择团队。

```sh
xcodebuild -project ios/LocalShelf.xcodeproj -scheme LocalShelf -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/localshelf-public-derived CODE_SIGN_IDENTITY=- build
swiftc ios/LibraryModels.swift ios/ProtocolChecks.swift -o /tmp/localshelf-protocol-checks
/tmp/localshelf-protocol-checks
```

`scripts/verify_ios_runtime.sh` 只接受显式指定、已经启动的模拟器及模拟器构建包。它会在该测试模拟器安装应用；不要传真实设备。iOS 隐私清单已随工程资源打包；分发者应按自己的修改再次核对 Apple 的要求，不代表可以直接通过 App Store 审核。

## Android 阅读与同步

需要 JDK 17、Android SDK 36、Gradle 8.13；两个工程使用 Android Gradle Plugin 8.13.0。自行设置 `ANDROID_HOME` 或不入库的 `local.properties`。源码不捆绑 Gradle/SDK，也不引用维护者的安装路径。

```sh
gradle -p android-reader assembleDebug assembleRelease
gradle -p android-sync assembleDebug assembleRelease
```

Debug 使用本机自动生成的调试证书；Release 输出未签名包。请用自己的签名流程分发，并保管好证书；更换证书不能覆盖已有安装。阅读端运行依赖见其 assets 中的许可证。

同步 App 包名 `local.shelf.sync`，阅读 App 包名 `local.shelf.reader.android`，可以同时安装。同步端的 `-PdailyUiChecks=true` 是隔离测试变体，不是日常安装包。所有 instrumentation 只在独立模拟器中执行，不对真实下载目录或 NAS 运行。

## NAS 同步与阅读服务

运行时 Python 3.12+，Docker 部署需要 Compose。同步端用 OpenSSL 创建自己的 TLS 证书；Reader 的封面派生使用 Pillow 12.3.0。

1. 创建并备份专用数据目录，为 Compose 中的 UID/GID 赋予适当权限。不能把全盘或系统目录当作书库根目录。
2. 在各组件目录将 `.env.example` 复制为 `.env`，填写自己的私网地址和绝对目录。不要提交 `.env` 或生成的数据。
3. 在 `nas-sync` 运行 `docker compose up -d --build`。启动会在专用数据根的 `config/` 生成 TLS 与 `pairing.json`；只将配对文件私下导入自己的 Android 同步端，不公开分享，不删除身份文件来解决普通网络问题。
4. 在 `nas-reader` 构建镜像，并交互式配置阅读密码：

```sh
docker compose build
docker compose run --rm -it localshelf-reader python /app/server.py --state /state --set-password
docker compose up -d
```

Reader 的 `/source` 必须对应现有同步数据且只读，`/state` 必须是另一个持久目录。未发布清单时 `/v2/ready` 返回 503，这是就绪状态，不是要求删除数据库。启用手动库需要额外创建独立目录并配置 `MANUAL_DATA_DIR`：

```sh
docker compose -f compose.yaml -f compose.manual.yaml up -d
```

Reader 健康检查每分钟运行一次，仅检查目录和索引元数据。Docker 的 unhealthy 标记不会自动修复或重启容器。NAS 启动依赖和网卡就绪策略取决于使用者系统；本仓库不安装某台私人 NAS 的 systemd 补丁。

合成测试不连接真实 NAS：

```sh
python3 -m venv .venv
.venv/bin/pip install -r nas-reader/requirements.txt
.venv/bin/python -m unittest discover -s nas-reader -q
.venv/bin/python -m unittest discover -s nas-sync/tests -q
.venv/bin/python nas-reader/check_sync_compatibility.py nas-sync/server.py
.venv/bin/python -m unittest discover -s web -q
```

## Windows 手动上传

需要 .NET 8 SDK，UI 使用 WPF，实际运行需要 Windows。核心检查可在其他支持 .NET 的系统上执行：

```sh
dotnet run --project windows-uploader/Checks/Checks.csproj
dotnet build windows-uploader/App/LocalShelfUploader.csproj -c Release
dotnet publish windows-uploader/App/LocalShelfUploader.csproj -c Release -r win-x64 --self-contained true
```

发布 .NET 自包含包时须保留对应运行时的许可和第三方通知；本仓库只提供源码。连接的是 Reader 地址和阅读密码，不是 Sync 上传端口或 NAS 管理员账号。

## Web 网关

Python 标准库实现，无前端构建步骤。先准备可用的 Reader，再配置 `web/.env` 并启动 Compose。网关不会替代 Reader。

`WEB_ORIGIN` 必须与浏览器实际访问源精确一致；`READER_UPSTREAM` 是网关能访问的固定 Reader 地址。不要把上游设置为任意用户提交的 URL，不使用通配 Origin。网关的 `/readyz` 依赖 Reader 0.1.18 的 `/v2/ready`，旧 Reader 应先升级。

公网使用需要你自行设置 HTTPS 反向代理和权限；不要公开 Sync 的配对文件，或把内网密码经公网明文 HTTP 发送。

## macOS 续签助手

需要 Apple Silicon、macOS 14+ 和 Xcode。构建不联网申请描述文件、不访问手机，也不会运行新 App：

```sh
bash macos-signer/test.sh
bash macos-signer/build.sh
```

输出位于 `macos-signer/.build/LocalShelf Signer.app`。这是本机 ad-hoc 签名，不是 Developer ID 公证或 App Store 包。

首次打开由你选择自己的 LocalShelf Xcode 工程、填写 10 位开发团队 ID、选择已配对且开启开发者模式的 iPhone；可选填写现有 `.app` 路径来读取期限。Apple ID 在 Xcode 中登录，助手不索取或保存 Apple ID 密码。公共版默认关闭自动续签，使用独立的 `LocalShelfSigner-Public` 配置目录，不读取原私人版设置。

助手目前面向 `local.shelf.reader` 这个 bundle ID。若你改变 iOS 的标识，必须同步审查助手中 `Settings.bundle` 和工程名称；不要放宽团队/设备/应用的匹配保护。续签会对匹配的开发描述文件进行可恢复备份、构建并覆盖安装，应先阅读界面说明并确认；不是无限期签名或绕过 Apple 规则。
