# GitHub 与 Mac / Windows 共用开发

本项目使用一个仓库、一个 `main` 分支和同一套 MATLAB 源码。两端从相同提交构建和安装 App；实验数据保存在各自电脑，启动时由用户选择。

## 1. 首次上传（Windows）

在 https://github.com/new 新建空仓库，建议名为 `fUSWorkspace`，先选择 Private。不要勾选 README、.gitignore 或 License；本地已准备 README 和 Git 配置，授权协议由所有者另行决定。

在项目目录打开 PowerShell。若尚未配置 Git 提交身份，使用自己的姓名和 GitHub 邮箱（也可使用 GitHub Settings → Emails 显示的 noreply 邮箱），仅配置当前仓库：

```powershell
git config user.name "你的姓名"
git config user.email "你的GitHub提交邮箱"
git remote add origin https://github.com/你的账号/fUSWorkspace.git
git push -u origin main
git push -u origin setup/cross-platform-review
```

本地已准备空的 main 基准提交，App 源码和双平台配置放在 `setup/cross-platform-review` 审查分支。首次上传这两个分支后，在 GitHub 创建该分支到 main 的 Pull Request，完成代码审查和 CI 后再合并。合并前若需要下载源码，请克隆审查分支：`git clone --branch setup/cross-platform-review https://github.com/你的账号/fUSWorkspace.git`。

项目已初始化 Git，不用再执行 `git init`。首次推送如弹出 Git Credential Manager 登录界面，登录你拥有此仓库的 GitHub 账号。不要把密码或访问令牌写入仓库地址或源文件。若已有 `origin`，先用 `git remote -v` 核对地址。

`.gitignore` 排除了 analysis、临时构建产物、实验数据、输出视频、MATLAB 本地设置和 macOS 临时文件。已发布安装包 `release/fUSWorkspace_1.5.2.mltbx` 和本地图标更新包 `release/fUSWorkspace_1.5.3.mltbx` 有明确例外，可以随源码提交；1.5.3尚未上传或发布到GitHub。通用源码、图标、实验计划示例和 MATLAB Project 元数据也受版本管理。scripts 中保留了既有的实验辅助脚本，其中一些含本机数据路径，不属于 App 的自动检查入口。

## 2. 私有仓库的 MATLAB 云端许可

私有仓库需要 MATLAB batch licensing token。通过 MathWorks 的 MATLAB Batch Licensing Pilot 页面申请：

https://www.mathworks.com/products/continuous-integration.html

在 GitHub 仓库 Settings → Secrets and variables → Actions → New repository secret 中添加：

- Name：`MLM_LICENSE_TOKEN`
- Secret：MathWorks 提供的批处理许可令牌

此令牌只填到 GitHub Secrets；它与 GitHub 登录令牌不同。许可配置完成后，在 Actions → MATLAB compatibility → Run workflow 重新运行。公开仓库使用 MathWorks Actions 支持的自动许可方式；源码公开与否由仓库所有者决定。

官方许可与平台说明：https://github.com/matlab-actions/setup-matlab

## 3. Mac 首次使用

Apple Silicon Mac 安装 MATLAB R2025a 或更新版本；Intel Mac 使用 R2025a 或 R2025b。还需要 Image Processing Toolbox 和 Computer Vision Toolbox。在终端克隆仓库：

```bash
git clone https://github.com/你的账号/fUSWorkspace.git
cd fUSWorkspace
```

在 MATLAB 中切换到克隆的项目目录。源码开发与验证：

```matlab
run("run_fUSWorkspace.m")
run("tests/run_all_tests.m")
```

需要安装到 Apps 页面时：

```matlab
run("build/build_mltbx.m")
appVersion = strtrim(string(fileread("VERSION")));
matlab.addons.install(fullfile("release", "fUSWorkspace_" + appVersion + ".mltbx"));
```

更新已安装 App 后，关闭旧窗口再重新打开。Git pull 更新的是源码；已安装的 App 通过安装包更新。

## 4. 日常同步

开始修改前先拉取；修改后先检查、测试，再提交和推送：

```bash
git pull --ff-only
git switch -c fix/简短英文问题名
# 修改后，在 MATLAB 中运行 tests/run_all_tests.m
git add app core tests build docs README.md VERSION
git diff --cached
git commit -m "描述本次修改"
git push -u origin HEAD
```

在 GitHub 上创建 Pull Request，合并到 main 前检查 `All supported platforms passed`。另一台电脑切换到 main 后执行 `git pull --ff-only` 即可取到合并的代码。两台电脑同时编辑时使用各自的功能分支。

可在仓库的 Rulesets 中把 `All supported platforms passed` 设置为 main 的必需检查；具体可用权限取决于账号方案。不要为 Mac 和 Windows 长期维护两份独立源码。

## 5. 自动检查覆盖范围

每次 push、Pull Request 或手动运行，工作流测试以下六个组合：

| 平台 | MATLAB |
|---|---|
| Windows | R2025a、R2026a |
| macOS Apple Silicon | R2025a、R2026a |
| macOS Intel | R2025a、R2025b |

MathWorks 从 R2026a 起停止支持 Intel Mac，因此 Intel 的上限检查使用 R2025b。官方说明：https://www.mathworks.com/support/requirements/apple-silicon.html

每个组合执行相同的静态检查、合成数据算法回归、ROI 时间窗重绘、App 窗口冒烟测试和安装包构建。两端计算结果各自与相同的已知数值比较。报告记录源码提交、MATLAB 版本、架构、工具箱和通过状态。失败日志和环境报告可在 Actions 的 Artifacts 中下载；只有测试与构建成功的组合才提供安装包。

六个组合全部成功，最终检查才通过。图标的实际显示、布局、播放流畅度和真实数据使用体验仍需在实体电脑上验收。云端首轮运行完成前，不应宣称 Mac 已通过兼容性验证。

## 6. 发布统一版本

版本号由根目录 `VERSION` 管理；构建脚本读取它生成安装包。发布时更新 VERSION 和 README 的版本说明，提交并完成六个组合检查，再创建对应标签，例如 `v1.5.3`：

```bash
git switch main
git pull --ff-only
git tag v1.5.3
git push origin v1.5.3
```

标签触发新的检查；CI 会拒绝与 VERSION 不一致的标签。全部检查通过后，在 GitHub Releases 中选择该标签，上传 Windows / R2025a 检查生成的 `.mltbx` 作为统一安装包，并附上两端验收结果。使用最低支持版本构建统一包，方便验证旧版 MATLAB 的安装兼容性。Mac 和 Windows 使用同一发布版本。工作流提供测试和打包，Release 由所有者发布。

Git 同步以提交和推送为单位；不会同步未保存的编辑内容，也不会自动替换正在运行的 App。

正式发布后，同时将选定安装包放进 `release/`，在 `.gitignore` 中为该文件添加例外，并提交到 main。发布说明和同一安装包仍保留在 GitHub Releases；这样既可单独下载 App，也可随源码 ZIP 一起下载。
