# 发布流程（Release Guide）

本文档说明 `honeybox` 发布新版本的完整流程。应用内「检查更新」依赖 **Gitee** 上的
**Release + tag + `.apk` 资产**，缺一不可，因此请严格按步骤操作。

正常发布只需**改版本号 → 打 tag → 推送**：推送 `vX.Y.Z` tag 后，GitHub Actions
（`.github/workflows/flutter-ci.yml`）会自动构建 Release APK，同时发布到 GitHub
（存档/海外）与 Gitee（国内用户实际使用），无需手动上传。手动建 Release 仅作 CI
不可用时的兜底。

> 以发布 `0.8.4` 为例，将命令中的版本号替换为实际版本即可。

## 前置条件

- 已安装 Flutter，`flutter doctor` 通过（仅本地构建/验证时需要；CI 会自行安装）。
- 仓库 remote 为 GitHub `realmcu/HoneyBox`（凭证已配置，可正常 `git push`）。
- CI 自动发布无需额外配置 `GITHUB_TOKEN`：`flutter-ci.yml` 的 release job 使用
  GitHub Actions 内置的 `GITHUB_TOKEN`（`permissions: contents: write`）创建
  GitHub Release。
- 已在 **GitHub 仓库 Settings → Secrets and variables → Actions** 配置名为
  `GITEE_TOKEN` 的 secret（Gitee 个人访问令牌，需 `projects` 与 push 代码权限），
  供 CI 双发到 Gitee 使用。⚠️ 令牌切勿写入代码/提交/日志。

  **关于 token 安全存储与日志脱敏：**

  - **加密存储**：secret 添加到 GitHub 仓库后以加密方式存储，网页上不再显示原文，
    只能覆盖或删除，无法查看。
  - **自动脱敏**：workflow 通过 `${{ secrets.GITEE_TOKEN }}` 引用。GitHub Actions
    对 secret 值有自动脱敏机制，凡出现在运行日志中的 token 原文一律被替换为 `***`，
    不会在日志里泄露。
  - **已规避常见泄露点**：本 CI 不使用 `set -x`；curl 传输加 `-s` 静默模式；token
    通过 `-F` 表单字段传给 Gitee API，而非拼入 URL query——避免 token 进入 Gitee
    侧服务器的访问日志。
  - **最小权限 + 短有效期**：建议给该 token 仅授予建 Release、上传附件、push 代码所
    需的最小权限，并设置较短的有效期，以降低万一泄露时的影响范围。

## 1. 修改版本号（两处，务必一致）

| 文件 | 字段 | 说明 |
| --- | --- | --- |
| `pubspec.yaml` | `version: X.Y.Z+N` | `N` 为 versionCode，每次发布 **递增** |
| `lib/app_info.dart` | `static String version = 'X.Y.Z';` | 仅作 pre-init 兜底，运行时由 package_info_plus 覆盖 |

两处的 `X.Y.Z` 必须完全一致，否则界面显示与更新判断会错乱。

## 2. 提交、打 tag、推送

```powershell
$ver = "0.8.4"
git add -A
git commit -m "chore: 版本号升至 $ver"
git tag -a "v$ver" -m "v$ver"
git push origin master "v$ver"
```

tag 命名固定为 `vX.Y.Z`（带 `v` 前缀），客户端会去掉 `v` 再比较版本。

## 3. 等待 CI 自动发布

推送 `vX.Y.Z` tag 后，`.github/workflows/flutter-ci.yml` 会自动：

1. `analyze` / `lint`：静态检查、测试、格式与 CI 策略检查。
2. `build-android`：`flutter build apk --release`，产物重命名为 **`HoneyBox.apk`**。
3. `build-windows`：构建 Windows x64。
4. `release`：仅在 `refs/tags/v*` 时触发：
   - 创建 GitHub Release（存档/海外），附 `HoneyBox.apk`；
   - 用 `GITEE_TOKEN` 把 tag 与 master push 到 Gitee `realmcu/HoneyBox`（两边代码同步）；
   - 计算 APK 的 SHA-256，调 Gitee API v5 创建同名 Release、上传 `HoneyBox.apk`，
     并在 notes 写入 `SHA-256: <hex>`（客户端下载时强校验）。
   - 任一 Gitee 步骤失败 → job 红（阻断）。

进度查看：<https://github.com/realmcu/HoneyBox/actions>。全部绿灯后，GitHub Release 会
出现在 <https://github.com/realmcu/HoneyBox/releases>，Gitee Release 会出现在
<https://gitee.com/realmcu/HoneyBox/releases>。

> ⚠️ 资产名 **必须**为 `HoneyBox.apk`（客户端匹配第一个以 `.apk` 结尾的资产名，
> 不区分大小写）。CI 已按此命名；若手动上传，务必保持一致，否则客户端找不到 APK、
> 不会提示更新。

## 4.（兜底）手动创建 Gitee Release

仅当 CI 不可用时使用（GitHub Release 可同步或单独创建用于存档）。先本地构建：

```powershell
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
# Release 使用 debug 签名（android/app/build.gradle 中 signingConfig = signingConfigs.debug），可直接安装
Copy-Item "build\app\outputs\flutter-apk\app-release.apk" `
          "build\app\outputs\flutter-apk\HoneyBox.apk"
```

### 方式 A：Gitee 网页手动（推荐兜底）

打开 <https://gitee.com/realmcu/HoneyBox/releases/new>，基于已推送的 `vX.Y.Z`
tag 创建 Release，在附件中上传 `HoneyBox.apk`，并在 Release notes 中追加
`SHA-256: <hex>`（见第 6 节）。

### 方式 B：同步创建 GitHub Release（存档/海外）

```powershell
$ver = "0.8.4"
gh release create "v$ver" `
  "build\app\outputs\flutter-apk\HoneyBox.apk" `
  --repo realmcu/HoneyBox `
  --title "HoneyBox v$ver" `
  --notes "本次更新内容……"
```

## 5. 验证「检查更新」

- 客户端逻辑见 `lib/services/update_service.dart`：读取 **Gitee**
  `releases/latest` 的 `tag_name`（去 `v` 前缀）与第一个 `.apk` 资产下载链接。
- 验证：

```powershell
Invoke-RestMethod "https://gitee.com/api/v5/repos/realmcu/HoneyBox/releases/latest" |
  Select-Object tag_name, @{n='apk';e={($_.assets | Where-Object { $_.name -like '*.apk' }).name}}
```

- ⚠️ 只打 tag、不上传 APK（或资产名不对），老版本 **不会** 提示更新。

## 6. SHA-256 强校验

CI 已在 Gitee Release notes 自动写入 `SHA-256: <hex>`，客户端下载时强校验，
可防镜像/传输篡改。手动兜底发布时需自行追加该行（见下）。

客户端已兼容强校验：若 Release notes（body）中声明了 SHA-256，下载与「复用本地已下载包」
时都会比对哈希；未声明则回退到「文件大小 + ZIP 魔数」弱校验。

生成哈希：

```powershell
(Get-FileHash -Algorithm SHA256 "build\app\outputs\flutter-apk\HoneyBox.apk").Hash.ToLower()
```

在 Release notes 中单独一行写入（大小写、连字符不敏感，正则从 body 中提取 64 位 hex）：

```
SHA-256: <上一步得到的 64 位小写 hex>
```

相关实现：`update_service.dart` 的 `_parseSha256` / `cachedApk` / `downloadApk`
中的 `expectedSha256`。

## 附：已发布 tag

`v0.8.0`、`v0.8.2`、`v0.8.3`（无 `v0.8.1`）。
