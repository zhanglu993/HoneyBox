# 七牛云文件

首页右上角菜单打开 **七牛云配置**，填写使用者自己的 AccessKey、SecretKey 和 Bucket。配置只保存在当前安装/系统用户的本机安全存储中，不会随安装包分发或同步给其他人。每个安装保存一组配置。

存储区域默认自动发现，也可手动选择。下载域名填写该空间绑定且可用的 HTTPS 域名，例如 `https://files.example.com`，不要附加文件路径或签名参数。列举和上传不要求先填写下载域名。根据实际空间选择“私有空间”；私有下载由本机生成一小时有效的签名地址。

“测试连接”使用当前表单只读列举一条记录，空空间也可成功；它不会保存配置或上传测试文件，不能证明上传与下载权限。“保存配置”不依赖网络测试。“清除本机配置”只清除本机账号信息，不删除云端文件。

连接测试时按钮显示“测试中…”，可点击“取消测试”。成功或失败会显示醒目的状态卡片和底部提示；测试总时限为 20 秒，超时会中止网络请求并显示原因。

首页菜单的 **七牛云文件** 可执行：

- 按路径前缀查询文件、分页加载和查看大小、类型、上传时间及 Hash。
- 选择本地文件上传。默认路径含时间和随机标识，可编辑；禁止覆盖同名对象。
- 下载文件，流式检查大小和七牛 Hash 后保存到系统选择的位置。
- 显示传输进度、取消及手动重试；下载失败会清理本机临时文件。

默认前缀只用于分类，不是权限边界。传输期间配置不可更换或清除。取消上传时会短时尽力清理未完成分片；清理未成功的分片由七牛到期回收。若完成请求的响应丢失，云端文件可能已经存在，重试遇到同名错误时先刷新列表核对，不会覆盖原文件。

首版只提供通用文件操作。采集记录仍按原有方式保存，不自动上传或成组同步。没有云端删除、覆盖、后台保活及重启后断点恢复。“查看”指浏览清单和文件元信息，不提供云端编辑或全文预览。

## 平台与开发

当前实现 Android 和 Windows。七牛 REST、签名及分片传输均为纯 Dart，没有七牛原生 SDK 或平台绑定；本轮不创建 iOS 工程或实现 iOS 导出。

AK/SK 和配置作为单条记录存入 `flutter_secure_storage`；Android 使用 Keystore 包装密钥及 AES-GCM，Windows 使用插件的系统凭据/加密存储。Android 的密文和包装密钥均排除云备份和设备迁移，安全存储失败不回退为明文。

Windows 构建除原有 Flutter/Visual Studio 要求外，还需要 Visual Studio Installer 中的 **C++ ATL for latest v143 build tools (x86 & x64)**（`Microsoft.VisualStudio.Component.VC.ATL`）。缺少时会报 `atlstr.h` 不存在。2026-10-26 用户安装该组件后，Windows Release 构建已通过。运行时需保留 Release 目录中的 DLL 和 data 等配套文件。

七牛相关测试：`flutter test test/services/qiniu test/pages/qiniu`。覆盖独立 HMAC 向量、编码、分页、错误脱敏、分片重试、空文件、源文件变化、取消、下载大小/Hash 校验、中文文件名和配置/文件页面交互。真实账户及 Android 系统保存对话框仍需使用者在目标设备验收；自动测试不访问真实七牛空间。

参考：[管理签名](https://developer.qiniu.com/kodo/1201/access-token)、[上传策略](https://developer.qiniu.com/kodo/manual/put-policy)、[分片上传 v2](https://developer.qiniu.com/kodo/6364/multipartupload-interface)、[下载凭证](https://developer.qiniu.com/kodo/manual/download-token)。
