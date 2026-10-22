# fUS Workspace MATLAB 开发源码

**当前本地安装包：** [fUS Workspace 1.7.2（Mac / Windows）](release/fUSWorkspace_1.7.2.mltbx)。已发布的上一版：[下载1.5.2](https://github.com/YuwenTianhao/fUSWorkspace/raw/refs/heads/main/release/fUSWorkspace_1.5.2.mltbx)。

本仓库为私有仓库，下载前请先登录有访问权限的GitHub账号。当前本地安装包为`release/fUSWorkspace_1.7.2.mltbx`，尚未上传或发布到GitHub。在MATLAB中打开`.mltbx`安装，再从Apps页面启动。

这是fUS Workspace 1.7.2的可继续开发版本。支持最多4截面同步对照、跨截面曲线、播放亮点和已播放轨迹。点击「计算CBV与全部ROI」会自动更新项目ROI总览中的全部截面和ROI，包括未显示的截面与隐藏ROI。选择标注对象不交换画面位置；全部图像区统一深色，支持放大标注、缩放和平移。ROI名称默认隐藏。视频先预览，可调整曲线位置、占比和分辨率。手绘显示掩膜不改变定量。1.6/1.7项目配置和ROI可继续使用。详见[实验项目与多截面](docs/实验项目与多截面.md)。

## macOS图标与窗口行为

- 安装包附带新版蓝色脑形、红橙色反应区和接收端图标；蓝色圆框外为透明区域，无白色外框。MATLAB Apps 工具栏是否采用此图标取决于 MATLAB 版本的 App Gallery 支持。
- App窗口使用同一套图标；再次从Apps页面启动时，不重复创建窗口，而是恢复已有窗口并置前。
- macOS程序坞中的`MATLABWindow Helper`属于MATLAB的窗口宿主，不属于本项目。MATLAB App源码不能替换它的程序坞身份，也不能接收它的“重新打开”事件。不要修改MATLAB安装目录中的Helper应用，否则会破坏签名并在MATLAB升级后失效。
- 如果发布目标要求独立的程序坞图标、应用名称和点击置前行为，应另行构建独立macOS应用；本项目当前保持为MATLAB Apps页应用。

## 从哪里开始

Mac / Windows 共用开发、GitHub 首次上传、云端自动检查和版本发布步骤见 [GitHub与双平台开发](docs/GitHub与双平台开发.md)。统一版本号由根目录 `VERSION` 管理。

在 MATLAB 中把当前目录切换到本项目，然后运行：

```matlab
run("run_fUSWorkspace.m")
```

首次启动点击「打开实验」，选择包含多个截面的上层目录。若同时检测到PDI和BMP/PNG，项目优先使用PDI，不重复列出显示图。也可从菜单选择单个数据目录，App会寻找上层已有项目并定位该截面。之后启动自动恢复上次项目。

默认实验计划为：0–60秒静息baseline、60–90秒右后爪夹捏、90–150秒
休息、150–180秒右后爪夹捏、180–240秒休息。默认baseline同步为0–60秒。

## ROI 的 CBV 曲线

载入数据后，点击「添加多边形ROI」，逐点点击、双击结束。点击轮廓选中后可以拖动顶点或整体移动；双击列表名称可以重命名。轮廓、列表与曲线同步突出，点击曲线定位对应图像。点击「计算CBV与全部ROI」更新当前baseline并自动重算项目ROI总览内的全部ROI；「更新全部ROI曲线」也可单独启动这一统一更新。无ROI的截面跳过，完成后恢复原截面、对照选择和缩放视野，不自动生成批处理结果目录。「导出ROI曲线」生成CSV及带名称、单位、参数的MAT。曲线取ROI内各像素的CBV数值平均；显示阈值与透明度不参与数值计算。ROI及分析缓存按截面自动保存，不在不同截面间复制。

曲线背景按实验计划显示时间窗：蓝色为静息/休息，橙色为刺激，并标注阶段名称。修改实验计划后，时间窗立即更新。播放按实际经过时间定位帧；如果某次读取或绘制较慢，会追到当前时间对应的帧，避免后续播放持续落后。

如果你要修改或新增算法，先阅读 `docs/如何添加新算法.md`，通常不需要进入 App 控制器。

## 目录及用途

```text
fUSWorkspace/
├── app/
│   ├── fUSWorkspaceAppV2.m          App行为、状态和工作流调度
│   ├── fUSWorkspaceLayout.m         窗口、控件和布局
│   ├── fUSWorkspaceProject.m        共用配置与逐截面状态
│   ├── fUSWorkspaceProjectWorkflow.m 项目切换、自动恢复与批处理
│   ├── fUSWorkspaceComparisonWorkflow.m 同步截面对照与ROI总览
│   ├── fUSWorkspaceExportPreview.m  导出逐帧预览与布局调整
│   └── fUSWorkspaceMatlabApp.m      MATLAB Apps页入口
├── core/+fus/
│   ├── ImageSequence.m              图像发现、排序、读取和缓存
│   ├── PDISequence.m                PDI头部校验、线性数据读取和显示重建
│   ├── CBVEngine.m                  baseline与CBV数值算法
│   ├── ExperimentPlan.m             实验阶段表和时间匹配
│   ├── ExperimentStore.m            截面发现、相对路径与原子保存
│   ├── FrameRenderer.m              色表、叠加和视频帧渲染
│   └── ReportRenderer.m             科研汇报画布、轨迹与当前亮点
├── tests/
│   ├── testCoreAlgorithms.m         可手算合成数据的回归测试
│   └── run_all_tests.m              静态检查、算法测试和界面冒烟测试
├── docs/                             源码导航和开发指南
├── examples/                         实验计划CSV示例
├── build/                            工具箱打包脚本
├── assets/icons/                     图标母版、各尺寸导出与设计说明
├── release/                          安装包（当前本地版1.7.2）
├── resources/project/                MATLAB Project自动维护的元数据
├── fUSWorkspaceMATLABSource.prj      MATLAB Project入口
└── run_fUSWorkspace.m                开发启动脚本
```

`resources/project`中的XML用于MATLAB Project的文件、路径和项目状态管理，不应手工修改。`release`中的MLTBX通过`build/build_mltbx.m`生成；本地1.7.2安装包与历史版本均保留。其它构建产物继续忽略。

图标的唯一母版在 `assets/icons/fUSWorkspace_AppIcon_master.png`。同目录16、24、128和256像素图标均由母版缩放；打包脚本会同步更新 `app/assets/icons` 与 `resources/assets/icons` 中的Apps注册用副本。

## 算法入口

CBV数值计算只有两个主要入口：

```matlab
baseline = fus.CBVEngine.computeBaseline(sequence, timeRange, actualFPS, parameters);
[map, indices] = fus.CBVEngine.calculateMap(sequence, baseline, centerIndex, parameters);
```

未知log模式输出 `当前平均灰度 - baseline平均灰度`，单位为 Δlog灰度。只有确认输入映射后，已标定模式才输出相对 Power Doppler 百分比。

## 运行测试

```matlab
run("tests/run_all_tests.m")
```

测试覆盖原有数值算法、多截面发现和保存、移动目录恢复、ROI编辑与联动、共享参数、批处理以及载入失败时恢复原项目。

## 运行依赖

经 MATLAB 依赖分析确认：

- Windows / Apple Silicon Mac：MATLAB R2025a 或更新版本
- Intel Mac：MATLAB R2025a 或 R2025b（MathWorks 从 R2026a 起停止支持 Intel Mac）
- Image Processing Toolbox
- Computer Vision Toolbox

## 必须保持一致的规则

- 图像时间为 `图像序号 / 实际图像帧率`，所以2 Hz时第一张图是0.5秒。
- 数值算法只放在 `core/+fus`，不要重新写入界面回调。
- 显示参数不应改变 `CBVMap` 的数值，只改变叠加和视频外观。
- 新增参数时，`cbvParameters`、`collectConfiguration` 和 `applyConfiguration` 要同步更新。
- 修改算法后必须给 `tests/testCoreAlgorithms.m` 增加回归测试。
