# GitHub 发布前检查

- 只上传此公开目录或由发布脚本生成的 ZIP，不上传上层工作区、历史包、测试日志、签名 APK/IPA 或截图。
- 重新运行 `sh scripts/check.sh` 与安卓检查，确认允许文件清单与源码一致；新增文件先评审再加入 `PUBLIC_FILES.txt`。
- 核实 LICENSE 署名及授权、第三方依赖版本与完整许可声明。引用参考项目不代表可以无条件复制其源码。
- 图标为 AI 生成；没有做商标注册／相似性检索，不宣称官方关系、独占权或第三方背书。
- 公开仓库不需要 Apple ID、Android Keystore 或个人邮箱。提交前设置公开昵称和 GitHub 的 noreply 邮箱；仓库账户与提交昵称本身仍是公开信息。
- 不导入原开发仓库历史。本准备包没有 `.git`，也没有远端；建立新仓库后再检查首个提交内容。
- 在 GitHub 开启私密漏洞报告、可用的 secret scanning / push protection。不要在 Issue 模板要求上传真实书库或设备原始日志。
- 仅准备源码不等于已经发布，也不等于 App Store／Google Play 审核通过、商标检索或律师审计。
- 若新增其他人的代码、图像、服务或遥测，重新检查许可和隐私声明。

GitHub 官方提醒：已经发布的秘密可能留在克隆或缓存中，单纯删除文件不能撤销泄露；应先轮换凭据，再处理历史。因此首次发布前应检查最终包，而不是依赖事后删除。[官方说明](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)
