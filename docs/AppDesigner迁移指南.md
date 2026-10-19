# 迁移到 MATLAB App Designer

## 目标

新建一个可以在 Design View 中拖拽修改的 `.mlapp`，继续复用当前 App 的读取、CBV、时间戳和 MP4 导出逻辑。

## 1. 新建界面

在 MATLAB 中执行 `appdesigner`，选择 **Blank App**。建议先放置：

- 一个 `UIAxes`，组件名改成 `BrowserAxes`；
- 一个 `TabGroup`，包含 `BrowserTab`、`CBVTab`、`ExperimentTab`；
- 一个时间轴 `TimelineSlider`；
- 两个数值框 `ActualFPSField`、`PlaybackFPSField`；
- 两个表格 `BookmarkTable`、`ExperimentPlanTable`；
- README 和下表列出的其余控件。

组件名应与 `fUSWorkspaceAppV2.m` 的 properties 名称一致。现有控件的创建和默认布局可直接参考 `app/fUSWorkspaceLayout.m`。

### Design View 中需要命名的主要组件

| 组件名 | App Designer 类型 | 用途 |
|---|---|---|
| `UIFigure` | Figure | 主窗口 |
| `ImagePanel` | Panel | 共享画面外框及标题 |
| `BrowserAxes` | UIAxes | 原图与 CBV 共用画布 |
| `TabGroup` | Tab Group | 右侧三个控制页 |
| `BrowserTab` / `CBVTab` / `ExperimentTab` | Tab | 浏览、CBV、实验计划 |
| `DataFolderLabel` / `ResultFolderLabel` / `StatusLabel` | Label | 路径和运行状态 |
| `UnitLabel` / `PhaseLabel` / `FrameLabel` | Label | CBV单位、阶段、图片序号 |
| `TimelineSlider` | Slider | 共享时间轴 |
| `PlayButton` | Button | 播放/暂停 |
| `ActualFPSField` / `PlaybackFPSField` | Numeric Edit Field | 实验时间与视频播放速度 |
| `BrowserColormapDropDown` | Drop Down | 原图色表 |
| `TimestampCheckBox` / `ShowPhaseCheckBox` | Check Box | 时间戳和阶段名 |
| `WidthField` / `HeightField` | Numeric Edit Field | 共享画布比例 |
| `LockRatioCheckBox` | Check Box | 锁定宽高比 |
| `BookmarkTable` / `ExperimentPlanTable` | Table | 时间点与实验阶段 |
| `BaselineStartField` / `BaselineEndField` | Numeric Edit Field | baseline范围 |
| `SpatialAverageField` / `TemporalAverageField` | Numeric Edit Field | 空间和时间平均 |
| `ConversionDropDown` | Drop Down | 输入图语义 |
| `DynamicRangeField` / `Log10ScaleField` | Numeric Edit Field | 标定参数 |
| `MinimumBaselineField` | Numeric Edit Field | 信号掩膜阈值 |
| `LowThresholdField` / `HighThresholdField` | Numeric Edit Field | 显示阈值和色条范围 |
| `TransparencySlider` | Slider | CBV叠加透明度 |
| `ShowBackgroundCheckBox` / `BrainMaskCheckBox` | Check Box | 解剖背景和信号掩膜 |
| `ComputeBaselineButton` / `SaveCBVButton` | Button | baseline和当前结果 |
| `ExportCBVVideoButton` | Button | 所见即所得CBV视频 |

`CBVAxes` 不是第二个画布，而是指向 `BrowserAxes` 的内部属性。`BrowserImage`、`TimestampText`、`CBVBackgroundImage`、`CBVActivityImage` 和 `CBVColorBar` 也是运行时图形句柄，应作为 Private Property 添加，不需要在 Design View 拖放。

## 2. 不要复制界面构建代码

`app/fUSWorkspaceLayout.m` 中以下方法只负责创建控件，Design View 已经替代它们：

```text
buildUI
buildTopBar
buildTabs
buildBrowserTab
buildCBVTab
buildExperimentTab
buildTimeline
addControlLabel
```

行为回调可参考 `fUSWorkspaceAppV2.m`，但不要把算法复制进 `.mlapp`。新的 App 应继续调用 `fus.ImageSequence`、`fus.CBVEngine`、`fus.ExperimentPlan` 和 `fus.FrameRenderer`。

## 3. 添加状态属性

在 Code View 的 Property 菜单中添加 Private Property，把原文件“数据与运行状态”区域中的属性复制进去。Design View 自动创建的组件属性不要重复添加。

必须保留的状态包括：`Files`、`FrameStarts`、`FrameEnds`、`DataFolder`、`ResultFolder`、`CurrentIndex`、`PlaybackTimer`、`Cache`、`Bookmarks`、`ExperimentPlan`、`BaselineGray`、`BaselineSignal`、`AnalysisMask`、`CurrentCBVMap`、`IsBaselineValid`、`IsBusy` 和 `CurrentViewMode`。

## 4. StartupFcn

在 App Designer 中给 UIFigure 添加 `StartupFcn`，使用下面的初始化顺序：

```matlab
app.Cache = containers.Map(KeyType="char", ValueType="any");
app.Bookmarks = table([], [], strings(0, 1), strings(0, 1), ...
    VariableNames=["Frame", "Time_s", "File", "Note"]);
app.ExperimentPlan = app.defaultExperimentPlan();
app.ExperimentPlanTable.Data = app.ExperimentPlan;
app.CBVAxes = app.BrowserAxes;
app.BrowserAxes.XTick = [];
app.BrowserAxes.YTick = [];
app.BrowserAxes.YDir = "reverse";
colormap(app.BrowserAxes, app.blueWhiteOrange(256));
app.CBVColorBar = colorbar(app.BrowserAxes);
app.CBVColorBar.Visible = "off";
app.PlaybackTimer = timer( ...
    ExecutionMode="fixedSpacing", BusyMode="drop", Period=0.1, ...
    TimerFcn=@(~, ~)app.playbackTick());
app.updateConversionControls();
```

## 5. 按钮和控件回调

在 Design View 选中组件，添加对应回调，然后在回调内部调用现有私有方法：

| 组件/操作 | 回调中调用 |
|---|---|
| 选择数据文件夹 | `app.chooseDataFolder()` |
| 选择结果文件夹 | `app.chooseResultFolder()` |
| 保存/载入工作区 | `app.saveWorkspace()` / `app.loadWorkspace()` |
| 计算 baseline | `app.computeBaseline()` |
| 保存当前 CBV | `app.saveCurrentCBVResult()` |
| 导出 CBV MP4 | `app.exportCBVVideo()` |
| 普通 MP4 | `app.exportVideo()` |
| 播放 | `app.togglePlayback()` |
| 时间轴变化 | `app.sliderMoving(event.Value)` |
| 透明度拖动 | `app.transparencyChanging(event.Value)` |
| 实际帧率变化 | `app.actualFPSChanged()` |
| 播放帧率变化 | `app.playbackFPSChanged()` |

例如 App Designer 自动生成的按钮回调应保持很薄：

```matlab
function ExportCBVVideoButtonPushed(app, event)
    app.exportCBVVideo();
end
```

## 6. 关闭窗口时释放定时器

给 UIFigure 添加 `CloseRequestFcn`，先停止并删除 `PlaybackTimer`，再删除窗口。可以直接复用原文件的 `closeApp` 和 `delete` 清理逻辑，避免 MATLAB 关闭窗口后定时器仍在运行。

## 7. 迁移后的核对清单

- 第一张图在 2 Hz 下显示 0.5 s，而不是 0 s；
- baseline 范围映射到正确图片序号；
- 未知 log 模式明确显示 Δlog 灰度，不显示 CBV%；
- 切换到 CBV 页后，导出按钮生成 CBV 而不是原图；
- MP4 帧数等于 SVD 图片数；
- MP4 播放帧率不改变画面上的实验时间戳；
- 中文实验阶段不会触发 `insertText` 字体警告；
- 保存工作区后能恢复全部显示和导出参数。
