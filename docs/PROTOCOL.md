# LocalShelf 阅读协议摘要

这是当前客户端与安卓桥接实现的接口摘要，不是承诺兼容任意漫画服务。仅限可信私人局域网 HTTP IPv4。安卓默认 8088；NAS 阅读参考端口 8089，备份上传接口不在本仓库内。

## 配对

- 安卓 Bonjour：`_localshelf._tcp.`，服务名包含随机 `deviceId`。发现结果不代表可信身份。
- 六位配对码：`POST /v2/pair`，请求体为 6 个 ASCII 数字，不是 JSON。返回 `app=localshelf`、`version=2`、32 位小写十六进制 `deviceId` 和 32 字符 `[A-Za-z0-9_-]` token。
- 安卓码有效期 5 分钟，最多 5 次尝试，成功后失效。更新数字码不轮换长期 token。
- QR：JSON 字段 `app`、`version`、`address`、`token`、`deviceId`；备用二维码包含长期 token。客户端兼容旧 v1，但公开集成应使用 v2。
- 身份证明：`GET /v2/identity?nonce=<64位小写十六进制>`，返回 `deviceId` 与 `proof`。proof 是以 token 的 UTF-8 字节为密钥，对 `localshelf-server-v2\n<deviceId>\n<nonce>` 计算的 HMAC-SHA256 小写十六进制。
- 配对／身份证明不发 Bearer token；身份验证成功后 `/v1/*` 携带 `Authorization: Bearer <token>`。首次配对仍缺少 TLS 的信道认证与保密能力。
- NAS 模式额外检查 `/v2/health`：`app=localshelf-reader`、`version=1`、`serverKind=nas`，capabilities 至少含 `reader-v1`、`pair-v2`、`locate-v1`。当前安卓桥接不提供这个 NAS 探测接口。

## 阅读

| GET 路径 | 响应 |
|---|---|
| `/v1/books?offset=0&limit=100` | `orderVerified`、`total`、`books`，以及可选 `orderPolicy`、`catalogRevision`、`libraryId` |
| `/v1/books/{id}/cover` | 图片原字节或兼容的封面数据；可选 ETag/304 |
| `/v1/books/{id}/pages` | `{"pages":[{"number":1},{"number":3}]}`，数字递增，保留缺页 |
| `/v1/books/{id}/pages/{number}` | 图片／动图字节 |
| `/v1/books/{id}/position` | NAS 必需：`id`、`offset`、`catalogRevision`、`libraryId`；安卓端不提供，客户端分批查询定位 |

每个 book 含 `id`（1–20 位数字字符串）、`title`、`rank`（非负原列表位置），可带 `available` 和 64 位十六进制 `coverIdentity`。客户端分页为 50–500 本、50 的倍数，总数上限 20,000。稳定库身份及修订值格式以 `LibraryRules.validate` 为准。

安卓的 `orderVerified=false, orderPolicy=snapshot-query` 表示保存了数据库查询顺序，但同值记录的相对顺序尚未独立确认，不得改称已严格复原。客户端不会用 ID 或书名自动重排。

封面响应上限 8 MiB，正文 50 MiB；客户端不自动整本持久下载。状态码包括 401 凭据失效、403 配对被拒、404 不存在、409 冲突、503 尚未就绪；客户端不会把失败响应当作正常图片。

示例与测试使用 `192.168.240.*` / `192.168.241.*` 作为合成私网地址，不是可用公共服务或默认连接目标。不要用测试 token 部署真实服务。
