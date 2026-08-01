# Git hooks

本目录托管**版本控制里的** git hook 脚本,对齐 `.github/workflows/flutter-ci.yml` 的
lint / analyze 步骤 —— 在本地 commit 前就跑一遍,免得推到 CI 才被拒(v0.8.9 因
漏跑 `dart format` 挂过一次,v0.8.10 才补上)。

## 一次性启用(每台机器 / 每个 clone)

```bash
git config core.hooksPath tools/git-hooks
```

上面的命令是**本仓库级别**的,只影响这一个 clone。此后 `git commit` 会自动跑
`tools/git-hooks/pre-commit`。

## 目前包含

- `pre-commit` —— 提交前:
  1. `dart format lib/ test/` —— 有改动就重写文件,并把「本次原本 staged」
     的路径 re-add 进本次 commit;未 stage 的路径不会被顺手带进来。
  2. `flutter analyze` —— 有告警就拒 commit(analyze 无法自动修)。

## 临时绕过

```bash
git commit --no-verify
```

不推荐 —— GitHub Actions 的 `Dart Format Check` + `Analyze & Test` 两个 job
一样会跑同样的检查,`--no-verify` 只是把问题推到 CI 而已。

## Windows 备忘

- Git for Windows 自带的 `bash.exe` 会执行 shebang `#!/usr/bin/env bash`,
  所以 hook 用 bash 写而非 pwsh。任何装了 Git for Windows 的机器都能跑。
- 若 hook 报 `dart: command not found`,把 Flutter SDK 的 `bin/` 加到 PATH
  即可(Flutter 装好后一般已自动加);hook 也会 fallback 到 `flutter format`。
