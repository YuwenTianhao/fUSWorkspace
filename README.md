# fUS Workspace MATLAB 开发源码

这是 fUS Workspace 1.5.2 的可继续开发版本。界面、数据读取、CBV算法、实验计划和画面渲染已经分层，不绑定任何一次实验的绝对路径。1.5.2 修复实验计划时间窗在曲线重绘时叠加以及缩放定尺度错误。

## macOS图标与窗口行为

- 安装包附带自定义图标；MATLAB Apps 工具栏是否采用此图标取决于 MATLAB 版本的 App Gallery 支持。
- App窗口使用同一套图标；再次从Apps页面启动时，不重复创建窗口，而是恢复已有窗口并置前。
- macOS程序坞中的`MATLABWindow Helper`属于MATLAB的窗口宿主，不属于本项目。MATLAB App源码不能替换它的程序坞身份，也不能接收它的“重新打开”事件。不要修改MATLAB安装目录中的Helper应用，否则会破坏签名并在MATLAB升级后失效。
- 如果发布目标要求独立的程序坞图标、应用名称和点击置前行为，应另行构建独立macOS应用；本项目当前保持为MATLAB Apps页应用。

## 从哪里开始

Mac / Windows 共用开发、GitHub 首次上传、云端自动检查和版本发布步骤见 [GitHub与双平台开发](docs/GitHub与双平台开发.md)。统一版本号由根目录 `VERSION` 管理。

在 MATLAB 中把当前目录切换到本项目，然后运行：

```matlab
run("run_fUSWorkspace.m")
```

启动后选择实验文件夹或其中的 `SVD` 文件夹。若同时检测到 PDI 和
BMP/PNG，App 会询问使用哪一种；定量分析优先选择 PDI。

默认实验计划为：0–60秒静息baseline、60–90秒右后爪夹捏、90–150秒
休息、150–180秒右后爪夹捏、180–240秒休息。默认baseline同步为0–60秒。

## ROI 的 CBV 曲线

载入数据并计算 baseline 后，点击画面上方的「添加多边形ROI」。App 会切换到原图；逐点点击顶点，双击结束。可以重复添加多个 ROI。主窗口中间显示曲线和 ROI 列表：点击「计算/更新曲线」计算完整时间曲线，勾选「显示」列可单独显示或隐藏曲线与原图轮廓，选中列表中的任意一行后点击「删除选中ROI」即可删除它。新增 ROI 时，已经计算的曲线继续保留，只计算新增 ROI。曲线取 ROI 内各像素的 CBV 数值平均，沿用当前 baseline、空间平均和时间平均参数；显示阈值与透明度不参与数值计算。ROI 与显示状态随工作区一起保存，载入新数据时清空。

曲线背景按实验计划显示时间窗：蓝色为静息/休息，橙色为刺激，并标注阶段名称。修改实验计划后，时间窗立即更新。播放按实际经过时间定位帧；如果某次读取或绘制较慢，会追到当前时间对应的帧，避免后续播放持续落后。

如果你要修改或新增算法，先阅读 `docs/如何添加新算法.md`，通常不需要进入 App 控制器。

## 目录及用途

```text
fUSWorkspaceMATLABSource/
├── app/
│   ├── fUSWorkspaceAppV2.m          App行为、状态和工作流调度
│   ├── fUSWorkspaceLayout.m         窗口、控件和布局
│   └── fUSWorkspaceMatlabApp.m      MATLAB Apps页入口
├── core/+fus/
│   ├── ImageSequence.m              图像发现、排序、读取和缓存
│   ├── PDISequence.m                PDI头部校验、线性数据读取和显示重建
│   ├── CBVEngine.m                  baseline与CBV数值算法
│   ├── ExperimentPlan.m             实验阶段表和时间匹配
│   └── FrameRenderer.m              色表、叠加和视频帧渲染
├── tests/
│   ├── testCoreAlgorithms.m         可手算合成数据的回归测试
│   └── run_all_tests.m              静态检查、算法测试和界面冒烟测试
├── docs/                             源码导航和开发指南
├── examples/                         实验计划CSV示例
├── build/                            工具箱打包脚本
├── release/                          生成的开发版MLTBX
├── resources/project/                MATLAB Project自动维护的元数据
├── fUSWorkspaceMATLABSource.prj      MATLAB Project入口
└── run_fUSWorkspace.m                开发启动脚本
```

`resources/project` 中的 XML 不是业务代码，但它们用于 MATLAB Project 的文件、路径和项目状态管理，因此保留并且不应手工修改。`release` 中的 MLTBX 是构建产物，可以通过 `build/build_mltbx.m` 重新生成。

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

测试覆盖图像排序、baseline时间映射、两类CBV公式、时间平均边界、实验阶段边界、显示掩膜，以及 App 窗口创建。

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
