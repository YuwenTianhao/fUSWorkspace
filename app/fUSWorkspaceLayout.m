classdef fUSWorkspaceLayout < handle
    %FUSWORKSPACELAYOUT 只负责创建和排列 App 的界面组件。
    %
    % 这里没有数据读取或 CBV 算法。调整窗口布局、控件文字和默认显示值
    % 时修改本文件；算法参数的语义与计算仍由 core/+fus 管理。

    properties (SetAccess = private)
        UIFigure
        MainGrid
        TabGroup
        BrowserTab
        CBVTab
        ExperimentTab
        ImagePanel
        BrowserAxes
        CBVAxes
        CBVColorBar
        ROIStatusLabel
        ROITable
        ROICurveAxes
        DataFolderLabel
        ResultFolderLabel
        StatusLabel
        UnitLabel
        TimelineSlider
        FrameLabel
        PlayButton
        ActualFPSField
        PlaybackFPSField
        BrowserColormapDropDown
        TimestampCheckBox
        ShowPhaseCheckBox
        WidthField
        HeightField
        LockRatioCheckBox
        BookmarkTable
        ExperimentPlanTable
        PhaseLabel
        BaselineStartField
        BaselineEndField
        SpatialAverageField
        TemporalAverageField
        ConversionDropDown
        DynamicRangeField
        Log10ScaleField
        MinimumBaselineField
        LowThresholdField
        HighThresholdField
        TransparencySlider
        ShowBackgroundCheckBox
        BrainMaskCheckBox
        ComputeBaselineButton
        SaveCBVButton
        ExportCBVVideoButton
    end

    properties (Access = private)
        Callbacks struct
        Bookmarks table
        ExperimentPlan table
        IconFile string = ""
    end

    methods
        function layout = fUSWorkspaceLayout( ...
                callbacks, bookmarks, experimentPlan, iconFile)
            layout.Callbacks = callbacks;
            layout.Bookmarks = bookmarks;
            layout.ExperimentPlan = experimentPlan;
            layout.IconFile = string(iconFile);
            layout.buildUI();
        end

        function components = components(layout)
            names = [ ...
                "UIFigure", "MainGrid", "TabGroup", "BrowserTab", "CBVTab", ...
                "ExperimentTab", "ImagePanel", "BrowserAxes", "CBVAxes", ...
                "CBVColorBar", "ROIStatusLabel", "ROITable", "ROICurveAxes", ...
                "DataFolderLabel", "ResultFolderLabel", ...
                "StatusLabel", "UnitLabel", "TimelineSlider", "FrameLabel", ...
                "PlayButton", "ActualFPSField", "PlaybackFPSField", ...
                "BrowserColormapDropDown", "TimestampCheckBox", ...
                "ShowPhaseCheckBox", "WidthField", "HeightField", ...
                "LockRatioCheckBox", "BookmarkTable", "ExperimentPlanTable", ...
                "PhaseLabel", "BaselineStartField", "BaselineEndField", ...
                "SpatialAverageField", "TemporalAverageField", ...
                "ConversionDropDown", "DynamicRangeField", "Log10ScaleField", ...
                "MinimumBaselineField", "LowThresholdField", ...
                "HighThresholdField", "TransparencySlider", ...
                "ShowBackgroundCheckBox", "BrainMaskCheckBox", ...
                "ComputeBaselineButton", "SaveCBVButton", ...
                "ExportCBVVideoButton"];
            components = struct();
            for index = 1:numel(names)
                components.(names(index)) = layout.(names(index));
            end
        end
    end

    methods (Access = private)
        function buildUI(layout)
            layout.UIFigure = uifigure( ...
                Name="fUS统一工作区：浏览、CBV处理与结果共享", ...
                Position=[45, 45, 1500, 900], Color=[0.96, 0.97, 0.98]);
            if strlength(layout.IconFile) > 0 && isfile(layout.IconFile)
                layout.UIFigure.Icon = layout.IconFile;
            end
            layout.MainGrid = uigridlayout(layout.UIFigure, [3, 1]);
            layout.MainGrid.RowHeight = {72, "1x", 108};
            layout.MainGrid.Padding = [12, 12, 12, 12];
            layout.MainGrid.RowSpacing = 10;

            layout.buildTopBar();
            layout.buildTabs();
            layout.buildTimeline();
        end

        function buildTopBar(layout)
            grid = uigridlayout(layout.MainGrid, [2, 8]);
            grid.Layout.Row = 1;
            grid.RowHeight = {30, 28};
            grid.ColumnWidth = {125, "1x", 125, "1x", 110, 110, 145, 260};
            grid.Padding = [0, 0, 0, 0];

            chooseData = uibutton(grid, Text="选择数据文件夹", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.chooseDataFolder());
            chooseData.Layout.Row = [1, 2];
            chooseData.Layout.Column = 1;
            layout.DataFolderLabel = uilabel(grid, Text="尚未载入数据", FontWeight="bold");
            layout.DataFolderLabel.Layout.Row = 1;
            layout.DataFolderLabel.Layout.Column = 2;
            layout.UnitLabel = uilabel(grid, Text="CBV单位：Δlog灰度（不是CBV%）", ...
                FontColor=[0.68, 0.26, 0.08]);
            layout.UnitLabel.Layout.Row = 2;
            layout.UnitLabel.Layout.Column = 2;

            chooseResult = uibutton(grid, Text="选择结果文件夹", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.chooseResultFolder());
            chooseResult.Layout.Row = [1, 2];
            chooseResult.Layout.Column = 3;
            layout.ResultFolderLabel = uilabel(grid, Text="结果文件夹未设置");
            layout.ResultFolderLabel.Layout.Row = [1, 2];
            layout.ResultFolderLabel.Layout.Column = 4;

            saveWorkspaceButton = uibutton(grid, Text="保存工作区", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.saveWorkspace());
            saveWorkspaceButton.Layout.Row = [1, 2];
            saveWorkspaceButton.Layout.Column = 5;
            loadWorkspaceButton = uibutton(grid, Text="载入工作区", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.loadWorkspace());
            loadWorkspaceButton.Layout.Row = [1, 2];
            loadWorkspaceButton.Layout.Column = 6;

            layout.StatusLabel = uilabel(grid, Text="请选择数据文件夹", ...
                FontColor=[0.30, 0.34, 0.38]);
            layout.StatusLabel.Layout.Row = [1, 2];
            layout.StatusLabel.Layout.Column = [7, 8];
        end

        function buildTabs(layout)
            sharedGrid = uigridlayout(layout.MainGrid, [1, 3]);
            sharedGrid.Layout.Row = 2;
            sharedGrid.ColumnWidth = {"1.2x", "1x", 390};
            sharedGrid.Padding = [0, 0, 0, 0];
            sharedGrid.ColumnSpacing = 10;

            layout.ImagePanel = uipanel(sharedGrid, Title="共享画面 · 原始SVD", ...
                BackgroundColor=[0.06, 0.07, 0.08]);
            layout.ImagePanel.Layout.Column = 1;
            imageGrid = uigridlayout(layout.ImagePanel, [2, 1]);
            imageGrid.RowHeight = {30, "1x"};
            imageGrid.Padding = [5, 5, 5, 5];
            roiBar = uigridlayout(imageGrid, [1, 2]);
            roiBar.Layout.Row = 1;
            roiBar.ColumnWidth = {125, "1x"};
            roiBar.Padding = [0, 0, 0, 0];
            uibutton(roiBar, Text="添加多边形ROI", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.addPolygonROI());
            layout.ROIStatusLabel = uilabel(roiBar, Text="ROI: 0", ...
                FontColor=[0.92, 0.92, 0.92]);
            roiBar.BackgroundColor = [0.06, 0.07, 0.08];
            layout.BrowserAxes = uiaxes(imageGrid, Color=[0.04, 0.04, 0.05]);
            layout.BrowserAxes.Layout.Row = 2;
            layout.BrowserAxes.XTick = [];
            layout.BrowserAxes.YTick = [];
            layout.BrowserAxes.Box = "on";
            layout.BrowserAxes.Toolbar.Visible = "on";
            layout.BrowserAxes.YDir = "reverse";
            layout.CBVAxes = layout.BrowserAxes;
            colormap(layout.BrowserAxes, fus.FrameRenderer.blueWhiteOrange(256));
            layout.CBVColorBar = colorbar(layout.BrowserAxes);
            layout.CBVColorBar.Label.String = "Δlog灰度";
            layout.CBVColorBar.Visible = "off";

            curvePanel = uipanel(sharedGrid, Title="ROI CBV时间曲线");
            curvePanel.Layout.Column = 2;
            curveGrid = uigridlayout(curvePanel, [3, 1]);
            curveGrid.RowHeight = {30, "1x", 170};
            curveGrid.Padding = [6, 6, 6, 6];
            curveBar = uigridlayout(curveGrid, [1, 2]);
            curveBar.Layout.Row = 1;
            curveBar.ColumnWidth = {"1x", "1x"};
            curveBar.Padding = [0, 0, 0, 0];
            uibutton(curveBar, Text="计算/更新曲线", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.showROICurves());
            uibutton(curveBar, Text="删除选中ROI", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.removeSelectedROI());
            layout.ROICurveAxes = uiaxes(curveGrid);
            layout.ROICurveAxes.Layout.Row = 2;
            grid(layout.ROICurveAxes, "on");
            xlabel(layout.ROICurveAxes, "时间 (s)");
            ylabel(layout.ROICurveAxes, "CBV");
            layout.ROITable = uitable(curveGrid, ...
                Data=table(false(0, 1), strings(0, 1), zeros(0, 1), ...
                    VariableNames=["Visible", "ROI", "Pixels"]), ...
                ColumnName={"显示", "ROI", "像素"}, ...
                ColumnEditable=[true, false, false], ...
                ColumnWidth={55, "auto", 65}, ...
                CellEditCallback=@(~, event)layout.Callbacks.roiVisibilityChanged(event), ...
                CellSelectionCallback=@(~, event)layout.Callbacks.roiSelected(event));
            layout.ROITable.Layout.Row = 3;

            layout.TabGroup = uitabgroup(sharedGrid, ...
                SelectionChangedFcn=@(~, event)layout.Callbacks.viewTabChanged(event.NewValue));
            layout.TabGroup.Layout.Column = 3;
            layout.BrowserTab = uitab(layout.TabGroup, Title="浏览与导出");
            layout.CBVTab = uitab(layout.TabGroup, Title="CBV分析");
            layout.ExperimentTab = uitab(layout.TabGroup, Title="实验计划");
            layout.buildBrowserTab(layout.BrowserTab);
            layout.buildCBVTab(layout.CBVTab);
            layout.buildExperimentTab(layout.ExperimentTab);
        end

        function buildBrowserTab(layout, parentTab)
            grid = uigridlayout(parentTab, [1, 1]);
            grid.Padding = [6, 6, 6, 6];
            controlPanel = uipanel(grid, Title="共享画面、标记与导出");
            controls = uigridlayout(controlPanel, [12, 2]);
            controls.RowHeight = {28, 28, 28, 28, 28, 28, 28, 28, "1x", 28, 28, 28};
            controls.ColumnWidth = {120, "1x"};
            controls.Padding = [10, 10, 10, 10];
            controls.RowSpacing = 6;

            layout.addControlLabel(controls, "显示色表");
            layout.BrowserColormapDropDown = uidropdown(controls, ...
                Items=["原图", "hot", "gray", "parula", "turbo", "jet", "bone", "copper"], ...
                Value="原图", ValueChangedFcn=@(~, ~)layout.Callbacks.refreshBrowser());

            layout.TimestampCheckBox = uicheckbox(controls, ...
                Text="显示/导出时间戳", Value=true, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshSharedView());
            layout.TimestampCheckBox.Layout.Column = [1, 2];

            layout.addControlLabel(controls, "共享画布宽度");
            layout.WidthField = uieditfield(controls, "numeric", Value=256, ...
                Limits=[eps, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.widthChanged());
            layout.addControlLabel(controls, "共享画布高度");
            layout.HeightField = uieditfield(controls, "numeric", Value=424, ...
                Limits=[eps, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.heightChanged());

            layout.LockRatioCheckBox = uicheckbox(controls, ...
                Text="锁定当前宽高比", Value=false, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.lockRatioChanged());
            layout.LockRatioCheckBox.Layout.Column = [1, 2];

            addBookmarkButton = uibutton(controls, Text="记录当前时间点", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.addBookmark());
            addBookmarkButton.Layout.Column = [1, 2];
            deleteBookmarkButton = uibutton(controls, Text="删除选中标记", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.deleteBookmark());
            deleteBookmarkButton.Layout.Column = [1, 2];

            tableLabel = uilabel(controls, Text="共享时间标记（备注可编辑）", ...
                FontWeight="bold");
            tableLabel.Layout.Column = [1, 2];
            layout.BookmarkTable = uitable(controls, Data=layout.Bookmarks, ...
                ColumnEditable=[false, false, false, true], ...
                ColumnName={"帧", "时间(s)", "文件", "备注"}, ...
                ColumnWidth={45, 65, 115, "auto"});
            layout.BookmarkTable.Layout.Row = 9;
            layout.BookmarkTable.Layout.Column = [1, 2];

            saveMarksButton = uibutton(controls, Text="保存时间标记CSV", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.saveBookmarks());
            saveMarksButton.Layout.Column = [1, 2];
            exportVideoButton = uibutton(controls, Text="导出MP4", ...
                FontWeight="bold", ButtonPushedFcn=@(~, ~)layout.Callbacks.exportVideo());
            exportVideoButton.Layout.Column = [1, 2];
        end

        function buildCBVTab(layout, parentTab)
            grid = uigridlayout(parentTab, [1, 1]);
            grid.Padding = [6, 6, 6, 6];
            controlPanel = uipanel(grid, Title="共享画面的CBV处理参数");
            controls = uigridlayout(controlPanel, [16, 2]);
            % Keep every CBV control reachable on a 1280x720 display.  The
            % standalone App is often maximized onto a shorter screen than
            % the 1500x900 development window.
            controls.RowHeight = repmat({24}, 1, 16);
            controls.ColumnWidth = {150, "1x"};
            controls.Padding = [8, 8, 8, 8];
            controls.RowSpacing = 3;

            layout.addControlLabel(controls, "baseline开始 (s)");
            layout.BaselineStartField = uieditfield(controls, "numeric", Value=0, ...
                Limits=[0, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.addControlLabel(controls, "baseline结束 (s)");
            layout.BaselineEndField = uieditfield(controls, "numeric", Value=60, ...
                Limits=[0, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.addControlLabel(controls, "空间平均 (px)");
            layout.SpatialAverageField = uieditfield(controls, "numeric", Value=5, ...
                Limits=[1, 31], RoundFractionalValues="on", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.addControlLabel(controls, "时间平均 (帧)");
            layout.TemporalAverageField = uieditfield(controls, "numeric", Value=5, ...
                Limits=[1, 121], RoundFractionalValues="on", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.temporalAverageChanged());

            layout.addControlLabel(controls, "输入图语义");
            layout.ConversionDropDown = uidropdown(controls, ...
                Items=["未知log图", "8-bit dB图", "标定log10图", "线性功率图"], ...
                ItemsData=["unknown", "dB8bit", "log10Scaled", "linear"], ...
                Value="unknown", ValueChangedFcn=@(~, ~)layout.Callbacks.conversionChanged());
            layout.addControlLabel(controls, "总动态范围 (dB)");
            layout.DynamicRangeField = uieditfield(controls, "numeric", Value=60, ...
                Limits=[eps, 200], ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.addControlLabel(controls, "log10单位/灰度");
            layout.Log10ScaleField = uieditfield(controls, "numeric", Value=0.01, ...
                Limits=[eps, 1], ValueDisplayFormat="%.6f", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.addControlLabel(controls, "baseline灰度下限");
            layout.MinimumBaselineField = uieditfield(controls, "numeric", Value=35, ...
                Limits=[0, 255], ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.addControlLabel(controls, "低阈值 (绝对值)");
            layout.LowThresholdField = uieditfield(controls, "numeric", Value=0, ...
                Limits=[0, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBVDisplayOnly());
            layout.addControlLabel(controls, "显示范围 ±");
            layout.HighThresholdField = uieditfield(controls, "numeric", Value=15, ...
                Limits=[eps, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBVDisplayOnly());
            layout.addControlLabel(controls, "叠加透明度");
            layout.TransparencySlider = uislider(controls, Limits=[0, 1], Value=0.75, ...
                MajorTicks=[0, 0.5, 1], ...
                ValueChangingFcn=@(~, event)layout.Callbacks.transparencyChanging(event.Value), ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBVDisplayOnly());

            layout.ShowBackgroundCheckBox = uicheckbox(controls, ...
                Text="显示解剖背景", Value=true, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBV());
            layout.ShowBackgroundCheckBox.Layout.Row = 12;
            layout.ShowBackgroundCheckBox.Layout.Column = 1;
            layout.BrainMaskCheckBox = uicheckbox(controls, ...
                Text="信号掩膜", Value=true, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBVDisplayOnly());
            layout.BrainMaskCheckBox.Layout.Row = 12;
            layout.BrainMaskCheckBox.Layout.Column = 2;

            layout.ComputeBaselineButton = uibutton(controls, Text="计算/更新baseline", ...
                FontWeight="bold", Enable="off", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.computeBaseline());
            layout.ComputeBaselineButton.Layout.Row = 13;
            layout.ComputeBaselineButton.Layout.Column = [1, 2];
            layout.SaveCBVButton = uibutton(controls, Text="保存当前CBV图与数值", ...
                Enable="off", ButtonPushedFcn=@(~, ~)layout.Callbacks.saveCurrentCBVResult());
            layout.SaveCBVButton.Layout.Row = 14;
            layout.SaveCBVButton.Layout.Column = [1, 2];
            layout.ExportCBVVideoButton = uibutton(controls, ...
                Text="按当前显示导出CBV MP4", FontWeight="bold", ...
                Enable="off", ButtonPushedFcn=@(~, ~)layout.Callbacks.exportCBVVideo());
            layout.ExportCBVVideoButton.Layout.Row = 15;
            layout.ExportCBVVideoButton.Layout.Column = [1, 2];
            helpLabel = uilabel(controls, ...
                Text="橙=增强，蓝=抑制；未知标定时单位仅为Δlog灰度。", ...
                FontColor=[0.38, 0.42, 0.46]);
            helpLabel.Layout.Row = 16;
            helpLabel.Layout.Column = [1, 2];
        end

        function buildExperimentTab(layout, parentTab)
            grid = uigridlayout(parentTab, [7, 1]);
            grid.RowHeight = {32, 28, "1x", 32, 32, 32, 46};
            grid.Padding = [10, 10, 10, 10];
            grid.RowSpacing = 7;

            titleLabel = uilabel(grid, Text="功能实验阶段自动时间戳", ...
                FontWeight="bold");
            titleLabel.Layout.Row = 1;
            layout.ShowPhaseCheckBox = uicheckbox(grid, ...
                Text="在画面和导出视频中显示实验阶段", Value=true, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshSharedView());
            layout.ShowPhaseCheckBox.Layout.Row = 2;
            layout.ExperimentPlanTable = uitable(grid, Data=layout.ExperimentPlan, ...
                ColumnName={"开始(s)", "结束(s)", "阶段"}, ...
                ColumnEditable=[true, true, true], ...
                ColumnWidth={70, 70, "auto"}, ...
                CellEditCallback=@(~, ~)layout.Callbacks.experimentPlanChanged());
            layout.ExperimentPlanTable.Layout.Row = 3;

            resetButton = uibutton(grid, Text="恢复本次9分钟胡须实验计划", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.resetExperimentPlan());
            resetButton.Layout.Row = 4;
            loadButton = uibutton(grid, Text="载入实验计划CSV", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.loadExperimentPlan());
            loadButton.Layout.Row = 5;
            saveButton = uibutton(grid, Text="保存实验计划CSV", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.saveExperimentPlan());
            saveButton.Layout.Row = 6;
            helpLabel = uilabel(grid, ...
                Text="区间按 [开始, 结束) 判断；例如180.0 s自动进入右侧触摸。", ...
                FontColor=[0.38, 0.42, 0.46], WordWrap="on");
            helpLabel.Layout.Row = 7;
        end

        function buildTimeline(layout)
            grid = uigridlayout(layout.MainGrid, [3, 7]);
            grid.Layout.Row = 3;
            grid.RowHeight = {34, 30, 28};
            grid.ColumnWidth = {90, "1x", 110, 140, 110, 140, 180};
            grid.Padding = [0, 0, 0, 0];

            layout.PlayButton = uibutton(grid, Text="播放", Enable="off", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.togglePlayback());
            layout.PlayButton.Layout.Row = [1, 2];
            layout.PlayButton.Layout.Column = 1;
            layout.TimelineSlider = uislider(grid, Limits=[1, 2], Value=1, ...
                Enable="off", MajorTicks=[], ...
                ValueChangingFcn=@(~, event)layout.Callbacks.sliderMoving(event.Value), ...
                ValueChangedFcn=@(~, event)layout.Callbacks.sliderMoving(event.Value));
            layout.TimelineSlider.Layout.Row = 1;
            layout.TimelineSlider.Layout.Column = [2, 6];
            layout.FrameLabel = uilabel(grid, Text="0 / 0", HorizontalAlignment="right");
            layout.FrameLabel.Layout.Row = 1;
            layout.FrameLabel.Layout.Column = 7;

            actualLabel = uilabel(grid, Text="实际帧率", HorizontalAlignment="right");
            actualLabel.Layout.Row = 2;
            actualLabel.Layout.Column = 2;
            layout.ActualFPSField = uieditfield(grid, "numeric", Value=2, ...
                Limits=[0.01, 1000], ValueDisplayFormat="%.2f 帧/s", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.actualFPSChanged());
            layout.ActualFPSField.Layout.Row = 2;
            layout.ActualFPSField.Layout.Column = 3;
            playbackLabel = uilabel(grid, Text="播放/导出帧率", HorizontalAlignment="right");
            playbackLabel.Layout.Row = 2;
            playbackLabel.Layout.Column = 4;
            layout.PlaybackFPSField = uieditfield(grid, "numeric", Value=10, ...
                Limits=[0.1, 120], ValueDisplayFormat="%.2f 帧/s", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.playbackFPSChanged());
            layout.PlaybackFPSField.Layout.Row = 2;
            layout.PlaybackFPSField.Layout.Column = 5;
            layout.PhaseLabel = uilabel(grid, ...
                Text="共享画面：尚未载入数据", ...
                FontColor=[0.24, 0.32, 0.40], FontWeight="bold");
            layout.PhaseLabel.Layout.Row = 3;
            layout.PhaseLabel.Layout.Column = [1, 7];
        end

        function addControlLabel(~, grid, textValue)
            label = uilabel(grid, Text=textValue, HorizontalAlignment="right");
            label.Layout.Column = 1;
        end
    end
end
