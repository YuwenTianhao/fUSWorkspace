classdef fUSWorkspaceLayout < handle
    %FUSWORKSPACELAYOUT 图像为主、曲线在下、实验设置收纳在侧栏。
    % 这里只定义界面，不读取数据或计算CBV。

    properties (SetAccess = private)
        UIFigure
        MainGrid
        BodyGrid
        SettingsPanel
        ComparisonGrid
        ViewModeDropDown
        SectionListBox
        CrossROITable
        ShowAllSectionsCheckBox
        ComparisonTab
        ExportStyleDropDown
        ImageToolDropDown
        ROILabelsCheckBox
        ImageFocusButton
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
        SectionDropDown
        ExperimentStatusLabel
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
        function layout = fUSWorkspaceLayout(callbacks, bookmarks, experimentPlan, iconFile)
            layout.Callbacks = callbacks;
            layout.Bookmarks = bookmarks;
            layout.ExperimentPlan = experimentPlan;
            layout.IconFile = string(iconFile);
            layout.buildUI();
        end

        function result = components(layout)
            names = string(properties(layout));
            result = struct();
            for index = 1:numel(names)
                result.(names(index)) = layout.(names(index));
            end
        end
    end

    methods (Access = private)
        function buildUI(layout)
            layout.UIFigure = uifigure(Name="fUS Workspace · 实验分析", ...
                Position=[40, 40, 1600, 960], Color=[0.95, 0.96, 0.97]);
            if isprop(layout.UIFigure, "Theme")
                layout.UIFigure.Theme = "light";
            end
            if strlength(layout.IconFile) > 0 && isfile(layout.IconFile)
                layout.UIFigure.Icon = layout.IconFile;
            end
            layout.buildMenus();
            layout.MainGrid = uigridlayout(layout.UIFigure, [3, 1]);
            layout.MainGrid.RowHeight = {38, "1x", 66};
            layout.MainGrid.Padding = [10, 8, 10, 8];
            layout.MainGrid.RowSpacing = 8;
            layout.MainGrid.BackgroundColor = [0.95, 0.96, 0.97];
            layout.buildToolbar();
            layout.buildWorkspace();
            layout.buildTimeline();
        end

        function buildMenus(layout)
            fileMenu = uimenu(layout.UIFigure, Text="实验与项目");
            uimenu(fileMenu, Text="选择实验根目录…", ...
                MenuSelectedFcn=@(~, ~)layout.Callbacks.chooseExperimentFolder());
            uimenu(fileMenu, Text="选择单个数据文件夹…", ...
                MenuSelectedFcn=@(~, ~)layout.Callbacks.chooseDataFolder());
            uimenu(fileMenu, Text="打开项目或旧工作区…", Separator="on", ...
                MenuSelectedFcn=@(~, ~)layout.Callbacks.loadWorkspace());
            uimenu(fileMenu, Text="保存项目", ...
                MenuSelectedFcn=@(~, ~)layout.Callbacks.saveWorkspace());
            uimenu(fileMenu, Text="设置结果根目录…", Separator="on", ...
                MenuSelectedFcn=@(~, ~)layout.Callbacks.chooseResultFolder());
            viewMenu = uimenu(layout.UIFigure, Text="视图");
            uimenu(viewMenu, Text="图像聚焦 / 恢复曲线", ...
                MenuSelectedFcn=@(~, ~)layout.Callbacks.toggleImageFocus());
            uimenu(viewMenu, Text="展开 / 收起参数侧栏", ...
                MenuSelectedFcn=@(~, ~)layout.Callbacks.toggleSettings());
        end

        function buildToolbar(layout)
            bar = uigridlayout(layout.MainGrid, [1, 9]);
            bar.Layout.Row = 1;
            bar.ColumnWidth = {108, 72, "1x", 108, 96, 84, 84, 112, 100};
            bar.Padding = [0, 0, 0, 0];
            bar.ColumnSpacing = 7;
            bar.BackgroundColor = [0.95, 0.96, 0.97];
            uibutton(bar, Text="打开实验", FontWeight="bold", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.chooseExperimentFolder());
            uilabel(bar, Text="标注截面", HorizontalAlignment="right");
            layout.SectionDropDown = uidropdown(bar, Items="尚未载入实验", ...
                ItemsData="", Value="", Enable="off", ...
                Tooltip="选择正在标注的截面，不交换对照位置。也可点击对照图切换。", ...
                ValueChangedFcn=@(~, event)layout.Callbacks.sectionChanged(event.Value));
            layout.ViewModeDropDown = uidropdown(bar, ...
                Items=["原始图像", "CBV叠加"], ItemsData=["browser", "cbv"], ...
                Value="cbv", ValueChangedFcn=@(~, event) ...
                    layout.Callbacks.viewModeChanged(event.Value));
            uibutton(bar, Text="多截面对照", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.showComparisonPanel());
            uibutton(bar, Text="参数 / ROI", Tooltip="展开或收起实验设置侧栏", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.toggleSettings());
            uibutton(bar, Text="保存项目", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.saveWorkspace());
            uibutton(bar, Text="导出汇报视频", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.exportVideo());
            uibutton(bar, Text="批量处理", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.batchProcessSections());
        end

        function buildWorkspace(layout)
            layout.BodyGrid = uigridlayout(layout.MainGrid, [1, 2]);
            layout.BodyGrid.Layout.Row = 2;
            layout.BodyGrid.ColumnWidth = {"1x", 320};
            layout.BodyGrid.Padding = [0, 0, 0, 0];
            layout.BodyGrid.ColumnSpacing = 10;
            layout.BodyGrid.BackgroundColor = [0.95, 0.96, 0.97];

            workspace = uigridlayout(layout.BodyGrid, [3, 1]);
            workspace.Layout.Column = 1;
            workspace.RowHeight = {28, "2.7x", "1x"};
            workspace.RowSpacing = 6;
            workspace.Padding = [0, 0, 0, 0];
            workspace.BackgroundColor = [0.95, 0.96, 0.97];
            bar = uigridlayout(workspace, [1, 10]);
            bar.Layout.Row = 1;
            bar.ColumnWidth = {114, 108, 64, 98, 94, 52, 64, 72, 54, "1x"};
            bar.Padding = [0, 0, 0, 0];
            bar.BackgroundColor = [0.95, 0.96, 0.97];
            uibutton(bar, Text="添加多边形ROI", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.addPolygonROI());
            uibutton(bar, Text="绘制显示掩膜", ...
                Tooltip="只限制彩色叠加的显示区域，不改变ROI定量。", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.drawDisplayMask());
            uibutton(bar, Text="清除掩膜", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.clearDisplayMask());
            layout.ImageFocusButton = uibutton(bar, Text="放大标注", ...
                Tooltip="仅放大当前标注截面，暂时隐藏对照、曲线和侧栏；再次点击恢复。", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.toggleImageFocus());
            layout.ImageToolDropDown = uidropdown(bar, ...
                Items=["ROI编辑", "框选放大", "平移图像"], ...
                ItemsData=["edit", "zoom", "pan"], Value="edit", ...
                Tooltip="滚轮也可缩放；放大只改变视野，不改变ROI坐标或导出画面。", ...
                ValueChangedFcn=@(~, event)layout.Callbacks.imageToolChanged(event.Value));
            uibutton(bar, Text="缩小", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.zoomImageOut());
            uibutton(bar, Text="适应视野", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.resetImageView());
            layout.ROILabelsCheckBox = uicheckbox(bar, Text="ROI名称", Value=false, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.roiLabelsChanged());
            layout.ROIStatusLabel = uilabel(bar, Text="ROI: 0", ...
                FontColor=[0.25, 0.31, 0.37]);
            layout.DataFolderLabel = uilabel(bar, Text="打开实验后选择截面", ...
                FontColor=[0.35, 0.40, 0.45], HorizontalAlignment="right");

            layout.ComparisonGrid = uigridlayout(workspace, [2, 2]);
            layout.ComparisonGrid.Layout.Row = 2;
            layout.ComparisonGrid.RowHeight = {"1x", 0};
            layout.ComparisonGrid.ColumnWidth = {"1x", 0};
            layout.ComparisonGrid.Padding = [0, 0, 0, 0];
            layout.ComparisonGrid.RowSpacing = 6;
            layout.ComparisonGrid.ColumnSpacing = 6;
            layout.ComparisonGrid.BackgroundColor = [0.025, 0.03, 0.04];
            layout.ImagePanel = uipanel(layout.ComparisonGrid, ...
                Title="当前截面", FontWeight="bold", ...
                BackgroundColor=[0.025, 0.03, 0.04], ForegroundColor=[0.90, 0.93, 0.97]);
            layout.ImagePanel.Layout.Row = 1;
            layout.ImagePanel.Layout.Column = 1;
            imageGrid = uigridlayout(layout.ImagePanel, [1, 1]);
            imageGrid.Padding = [2, 2, 2, 2];
            imageGrid.BackgroundColor = [0.025, 0.03, 0.04];
            layout.BrowserAxes = uiaxes(imageGrid, Color=[0.025, 0.03, 0.04]);
            layout.BrowserAxes.XTick = [];
            layout.BrowserAxes.YTick = [];
            layout.BrowserAxes.Box = "off";
            layout.BrowserAxes.Toolbar.Visible = "off";
            layout.BrowserAxes.Interactions = zoomInteraction;
            layout.BrowserAxes.YDir = "reverse";
            layout.BrowserAxes.LooseInset = [4, 12, 10, 8];
            layout.CBVAxes = layout.BrowserAxes;
            colormap(layout.BrowserAxes, fus.FrameRenderer.blueWhiteRed(256));
            layout.CBVColorBar = colorbar(layout.BrowserAxes);
            layout.CBVColorBar.Label.String = "Δlog灰度";
            layout.CBVColorBar.Color = [0.90, 0.93, 0.97];
            layout.CBVColorBar.Visible = "off";

            curvePanel = uipanel(workspace, Title="ROI时间曲线 · 点击曲线定位图像", ...
                BackgroundColor="white", ForegroundColor=[0.18, 0.23, 0.28]);
            curvePanel.Layout.Row = 3;
            curveGrid = uigridlayout(curvePanel, [1, 1]);
            curveGrid.Padding = [4, 4, 4, 4];
            curveGrid.BackgroundColor = [1, 1, 1];
            layout.ROICurveAxes = uiaxes(curveGrid, Color="white");
            layout.ROICurveAxes.FontSize = 11;
            layout.ROICurveAxes.Box = "off";
            layout.ROICurveAxes.GridAlpha = 0.12;
            layout.ROICurveAxes.Toolbar.Visible = "off";
            grid(layout.ROICurveAxes, "on");
            xlabel(layout.ROICurveAxes, "时间 (s)");
            ylabel(layout.ROICurveAxes, "CBV");

            layout.SettingsPanel = uipanel(layout.BodyGrid, BorderType="none", ...
                BackgroundColor=[0.98, 0.98, 0.99]);
            layout.SettingsPanel.Layout.Column = 2;
            side = uigridlayout(layout.SettingsPanel, [2, 1]);
            side.RowHeight = {"1x", 34};
            side.Padding = [0, 0, 0, 0];
            side.BackgroundColor = [0.98, 0.98, 0.99];
            % 显示模式由顶部控件独立控制，切换参数标签页不再改变画面。
            layout.TabGroup = uitabgroup(side);
            layout.CBVTab = uitab(layout.TabGroup, Title="CBV");
            layout.ComparisonTab = uitab(layout.TabGroup, Title="截面 / ROI");
            layout.ExperimentTab = uitab(layout.TabGroup, Title="计划");
            layout.BrowserTab = uitab(layout.TabGroup, Title="显示 / 导出");
            layout.buildCBVTab(layout.CBVTab);
            layout.buildSectionTab(layout.ComparisonTab);
            layout.buildExperimentTab(layout.ExperimentTab);
            layout.buildDisplayTab(layout.BrowserTab);
            layout.ExperimentStatusLabel = uilabel(side, ...
                Text="实验配置共用 · ROI按截面保存", WordWrap="on", ...
                FontSize=10, FontColor=[0.36, 0.42, 0.48]);
            layout.ExperimentStatusLabel.Layout.Row = 2;
        end

        function buildCBVTab(layout, tab)
            controls = layout.sideGrid(tab, 18);
            controls.ColumnWidth = {120, "1x"};
            controls.RowHeight{7} = 38;
            controls.RowHeight{11} = 42;
            layout.sectionTitle(controls, 1, "计算 · 全部截面共用");
            layout.parameterLabel(controls, 2, "baseline开始 (s)");
            layout.BaselineStartField = uieditfield(controls, "numeric", Value=0, ...
                Limits=[0, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.placeControl(layout.BaselineStartField, 2);
            layout.parameterLabel(controls, 3, "baseline结束 (s)");
            layout.BaselineEndField = uieditfield(controls, "numeric", Value=60, ...
                Limits=[0, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.placeControl(layout.BaselineEndField, 3);
            layout.parameterLabel(controls, 4, "空间平均 (px)");
            layout.SpatialAverageField = uieditfield(controls, "numeric", Value=5, ...
                Limits=[1, 31], RoundFractionalValues="on", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.placeControl(layout.SpatialAverageField, 4);
            layout.parameterLabel(controls, 5, "时间平均 (帧)");
            layout.TemporalAverageField = uieditfield(controls, "numeric", Value=5, ...
                Limits=[1, 121], RoundFractionalValues="on", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.temporalAverageChanged());
            layout.placeControl(layout.TemporalAverageField, 5);
            layout.ComputeBaselineButton = uibutton(controls, Text="计算CBV与全部ROI", ...
                Tooltip="更新当前baseline，并自动计算项目ROI总览内所有截面的全部ROI。", ...
                FontWeight="bold", Enable="off", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.computeBaseline());
            layout.fullRow(layout.ComputeBaselineButton, 6);
            layout.UnitLabel = uilabel(controls, Text="Δlog灰度（未标定）", ...
                WordWrap="on", FontSize=10, FontColor=[0.60, 0.28, 0.10]);
            layout.fullRow(layout.UnitLabel, 7);

            layout.sectionTitle(controls, 8, "显示 · 不改变定量结果");
            layout.parameterLabel(controls, 9, "低阈值 (绝对值)");
            layout.LowThresholdField = uieditfield(controls, "numeric", Value=0, ...
                Limits=[0, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBVDisplayOnly());
            layout.placeControl(layout.LowThresholdField, 9);
            layout.parameterLabel(controls, 10, "显示范围 ±");
            layout.HighThresholdField = uieditfield(controls, "numeric", Value=15, ...
                Limits=[eps, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBVDisplayOnly());
            layout.placeControl(layout.HighThresholdField, 10);
            layout.parameterLabel(controls, 11, "彩色叠加强度");
            layout.TransparencySlider = uislider(controls, Limits=[0, 1], Value=0.75, ...
                MajorTicks=[0, 0.5, 1], ...
                ValueChangingFcn=@(~, event)layout.Callbacks.transparencyChanging(event.Value), ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBVDisplayOnly());
            layout.placeControl(layout.TransparencySlider, 11);
            layout.ShowBackgroundCheckBox = uicheckbox(controls, ...
                Text="显示解剖背景", Value=true, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBV());
            layout.fullRow(layout.ShowBackgroundCheckBox, 12);
            layout.BrainMaskCheckBox = uicheckbox(controls, ...
                Text="限制到手绘区域", Value=false, ...
                Tooltip="使用当前截面的手绘显示掩膜；没有掩膜时显示全部区域。", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshCBVDisplayOnly());
            layout.fullRow(layout.BrainMaskCheckBox, 13);
            drawButton = uibutton(controls, Text="绘制显示掩膜", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.drawDisplayMask());
            drawButton.Layout.Row = 14;
            drawButton.Layout.Column = 1;
            clearButton = uibutton(controls, Text="清除掩膜", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.clearDisplayMask());
            layout.placeControl(clearButton, 14);
            layout.SaveCBVButton = uibutton(controls, Text="保存当前CBV图与数值", ...
                Enable="off", ButtonPushedFcn=@(~, ~)layout.Callbacks.saveCurrentCBVResult());
            layout.fullRow(layout.SaveCBVButton, 15);
            layout.ExportCBVVideoButton = uibutton(controls, Text="导出CBV汇报视频", ...
                Enable="off", ButtonPushedFcn=@(~, ~)layout.Callbacks.exportCBVVideo());
            layout.fullRow(layout.ExportCBVVideoButton, 16);
            help = uilabel(controls, ...
                Text="ROI用于定量；显示掩膜用于突出脑区。两者独立，ROI内部仍显示CBV。", ...
                WordWrap="on", FontSize=10, FontColor=[0.38, 0.43, 0.48]);
            help.Layout.Row = [17, 18];
            help.Layout.Column = [1, 2];
        end

        function buildSectionTab(layout, tab)
            controls = uigridlayout(tab, [10, 1]);
            controls.RowHeight = {28, 112, 26, 28, 22, 112, 28, 28, 24, 130};
            controls.Padding = [8, 8, 8, 8];
            controls.RowSpacing = 6;
            controls.Scrollable = "on";
            controls.BackgroundColor = [0.98, 0.98, 0.99];
            uilabel(controls, Text="截面对照 · 最多同时显示4个", FontWeight="bold");
            layout.SectionListBox = uilistbox(controls, ...
                Items="尚未载入实验", ItemsData="", Value="", Enable="off", ...
                Multiselect="on", Tooltip="按Command/Ctrl多选截面，所有画面共用时间。", ...
                ValueChangedFcn=@(~, event)layout.Callbacks.comparisonSelectionChanged(event.Value));
            layout.ShowAllSectionsCheckBox = uicheckbox(controls, ...
                Text="显示跨截面ROI曲线", Value=true, ...
                Tooltip="叠加当前对照截面的有效ROI曲线；全部ROI仍保留在项目总览。", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.rebuildComparisonCurves());
            uibutton(controls, Text="更新项目全部ROI曲线", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.computeExperimentCurves());
            uilabel(controls, Text="当前截面ROI · 拖动顶点 / 双击名称编辑", FontWeight="bold", FontSize=10);
            layout.ROITable = uitable(controls, ...
                Data=table(false(0, 1), strings(0, 1), zeros(0, 1), ...
                    VariableNames=["Visible", "ROI", "Pixels"]), ...
                ColumnName={"显示", "ROI", "像素"}, RowName=[], ...
                ColumnEditable=[true, true, false], ColumnWidth={42, "auto", 54}, ...
                CellEditCallback=@(~, event)layout.Callbacks.roiVisibilityChanged(event), ...
                CellSelectionCallback=@(~, event)layout.Callbacks.roiSelected(event));
            rowBar = uigridlayout(controls, [1, 2]);
            rowBar.Padding = [0, 0, 0, 0];
            rowBar.ColumnWidth = {"1x", "1x"};
            uibutton(rowBar, Text="更新全部ROI曲线", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.showROICurves());
            uibutton(rowBar, Text="删除选中ROI", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.removeSelectedROI());
            uibutton(controls, Text="导出ROI曲线数据", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.exportROICurves());
            uilabel(controls, Text="项目ROI总览 · 点击切换到对应截面", FontWeight="bold", FontSize=10);
            layout.CrossROITable = uitable(controls, ...
                Data=table(strings(0, 1), strings(0, 1), strings(0, 1), ...
                    strings(0, 1), zeros(0, 1), ...
                    VariableNames=["SectionKey", "Section", "ROI", "Status", "ROIIndex"]), ...
                ColumnName={"路径", "截面", "ROI", "状态", "编号"}, RowName=[], ...
                ColumnEditable=false, ColumnWidth={0, 70, "auto", 70, 0}, ...
                CellSelectionCallback=@(~, event)layout.Callbacks.crossROISelected(event));
        end

        function buildExperimentTab(layout, tab)
            grid = uigridlayout(tab, [7, 1]);
            grid.RowHeight = {34, "1x", 28, 28, 28, 28, 54};
            grid.Padding = [8, 8, 8, 8];
            grid.RowSpacing = 6;
            grid.Scrollable = "on";
            grid.BackgroundColor = [0.98, 0.98, 0.99];
            layout.ShowPhaseCheckBox = uicheckbox(grid, ...
                Text="画面和视频显示实验阶段", Value=true, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshSharedView());
            layout.ExperimentPlanTable = uitable(grid, Data=layout.ExperimentPlan, ...
                ColumnName={"开始(s)", "结束(s)", "阶段"}, ...
                ColumnEditable=[true, true, true], ColumnWidth={60, 60, "auto"}, ...
                RowName=[], CellEditCallback=@(~, ~)layout.Callbacks.experimentPlanChanged());
            rowBar = uigridlayout(grid, [1, 2]);
            rowBar.Padding = [0, 0, 0, 0];
            rowBar.ColumnWidth = {"1x", "1x"};
            uibutton(rowBar, Text="添加阶段", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.addExperimentPhase());
            uibutton(rowBar, Text="删除选中阶段", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.deleteExperimentPhase());
            uibutton(grid, Text="载入实验计划CSV", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.loadExperimentPlan());
            uibutton(grid, Text="保存实验计划CSV", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.saveExperimentPlan());
            uibutton(grid, Text="恢复默认后爪实验计划", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.resetExperimentPlan());
            uilabel(grid, Text="全部截面共用同一计划。刺激时段直接标在曲线上，不再维护重复的时间书签。", ...
                WordWrap="on", FontSize=10, FontColor=[0.38, 0.43, 0.48]);
        end

        function buildDisplayTab(layout, tab)
            controls = layout.sideGrid(tab, 22);
            controls.ColumnWidth = {120, "1x"};
            layout.sectionTitle(controls, 1, "视频与显示");
            layout.parameterLabel(controls, 2, "导出样式");
            layout.ExportStyleDropDown = uidropdown(controls, ...
                Items=["汇报：图像＋曲线", "纯图像"], ...
                ItemsData=["presentation", "image"], Value="presentation");
            layout.placeControl(layout.ExportStyleDropDown, 2);
            layout.parameterLabel(controls, 3, "原图色表");
            layout.BrowserColormapDropDown = uidropdown(controls, ...
                Items=["原图", "gray", "bone", "hot", "parula", "turbo", "jet", "copper"], ...
                Value="原图", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshBrowser());
            layout.placeControl(layout.BrowserColormapDropDown, 3);
            layout.TimestampCheckBox = uicheckbox(controls, Text="显示时间戳", Value=true, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.refreshSharedView());
            layout.fullRow(layout.TimestampCheckBox, 4);
            layout.parameterLabel(controls, 5, "共享画布宽度");
            layout.WidthField = uieditfield(controls, "numeric", Value=256, ...
                Limits=[eps, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.widthChanged());
            layout.placeControl(layout.WidthField, 5);
            layout.parameterLabel(controls, 6, "共享画布高度");
            layout.HeightField = uieditfield(controls, "numeric", Value=424, ...
                Limits=[eps, Inf], ValueChangedFcn=@(~, ~)layout.Callbacks.heightChanged());
            layout.placeControl(layout.HeightField, 6);
            layout.LockRatioCheckBox = uicheckbox(controls, Text="锁定当前宽高比", Value=true, ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.lockRatioChanged());
            layout.fullRow(layout.LockRatioCheckBox, 7);
            layout.parameterLabel(controls, 8, "实际帧率");
            layout.ActualFPSField = uieditfield(controls, "numeric", Value=2, ...
                Limits=[0.01, 1000], ValueDisplayFormat="%.3f 帧/s", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.actualFPSChanged());
            layout.placeControl(layout.ActualFPSField, 8);
            layout.parameterLabel(controls, 9, "播放/导出帧率");
            layout.PlaybackFPSField = uieditfield(controls, "numeric", Value=10, ...
                Limits=[0.1, 120], ValueDisplayFormat="%.2f 帧/s", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.playbackFPSChanged());
            layout.placeControl(layout.PlaybackFPSField, 9);

            layout.sectionTitle(controls, 10, "输入标定 · 高级设置");
            layout.parameterLabel(controls, 11, "输入图语义");
            layout.ConversionDropDown = uidropdown(controls, ...
                Items=["未知log图", "8-bit dB图", "标定log10图", "线性功率图"], ...
                ItemsData=["unknown", "dB8bit", "log10Scaled", "linear"], Value="unknown", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.conversionChanged());
            layout.placeControl(layout.ConversionDropDown, 11);
            layout.parameterLabel(controls, 12, "总动态范围 (dB)");
            layout.DynamicRangeField = uieditfield(controls, "numeric", Value=60, ...
                Limits=[eps, 200], ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.placeControl(layout.DynamicRangeField, 12);
            layout.parameterLabel(controls, 13, "log10单位/灰度");
            layout.Log10ScaleField = uieditfield(controls, "numeric", Value=0.01, ...
                Limits=[eps, 1], ValueDisplayFormat="%.6f", ...
                ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.placeControl(layout.Log10ScaleField, 13);
            layout.parameterLabel(controls, 14, "baseline灰度下限");
            layout.MinimumBaselineField = uieditfield(controls, "numeric", Value=35, ...
                Limits=[0, 255], ValueChangedFcn=@(~, ~)layout.Callbacks.markBaselineDirty());
            layout.placeControl(layout.MinimumBaselineField, 14);

            layout.sectionTitle(controls, 15, "项目位置");
            resultButton = uibutton(controls, Text="设置结果根目录", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.chooseResultFolder());
            layout.fullRow(resultButton, 16);
            layout.ResultFolderLabel = uilabel(controls, Text="尚未设置", ...
                WordWrap="on", FontSize=10, FontColor=[0.38, 0.43, 0.48]);
            layout.ResultFolderLabel.Layout.Row = [17, 18];
            layout.ResultFolderLabel.Layout.Column = [1, 2];
            openButton = uibutton(controls, Text="打开项目", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.loadWorkspace());
            layout.fullRow(openButton, 19);
            description = uilabel(controls, Text="参数自动保存。画布宽高用于显示，不代表毫米标定。", ...
                WordWrap="on", FontSize=10, FontColor=[0.38, 0.43, 0.48]);
            description.Layout.Row = [20, 21];
            description.Layout.Column = [1, 2];
            % 只为旧工作区迁移保留数据容器，不再显示重复的时间书签功能。
            layout.BookmarkTable = uitable(controls, Data=layout.Bookmarks, ...
                Visible="off", ColumnEditable=[false, false, false, true]);
            layout.fullRow(layout.BookmarkTable, 22);
            controls.RowHeight{22} = 0;
        end

        function buildTimeline(layout)
            grid = uigridlayout(layout.MainGrid, [2, 4]);
            grid.Layout.Row = 3;
            grid.RowHeight = {32, 22};
            grid.ColumnWidth = {72, "1x", 178, 180};
            grid.Padding = [0, 0, 0, 0];
            grid.RowSpacing = 3;
            grid.BackgroundColor = [0.95, 0.96, 0.97];
            layout.PlayButton = uibutton(grid, Text="播放", Enable="off", ...
                ButtonPushedFcn=@(~, ~)layout.Callbacks.togglePlayback());
            layout.PlayButton.Layout.Row = 1;
            layout.PlayButton.Layout.Column = 1;
            layout.TimelineSlider = uislider(grid, Limits=[1, 2], Value=1, ...
                Enable="off", MajorTicks=[], ...
                ValueChangingFcn=@(~, event)layout.Callbacks.sliderMoving(event.Value), ...
                ValueChangedFcn=@(~, event)layout.Callbacks.sliderMoving(event.Value));
            layout.TimelineSlider.Layout.Row = 1;
            layout.TimelineSlider.Layout.Column = [2, 3];
            layout.FrameLabel = uilabel(grid, Text="0 / 0", HorizontalAlignment="right");
            layout.FrameLabel.Layout.Row = 1;
            layout.FrameLabel.Layout.Column = 4;
            layout.PhaseLabel = uilabel(grid, Text="尚未载入实验", ...
                FontWeight="bold", FontSize=11, FontColor=[0.25, 0.31, 0.37]);
            layout.PhaseLabel.Layout.Row = 2;
            layout.PhaseLabel.Layout.Column = [1, 2];
            layout.StatusLabel = uilabel(grid, Text="打开实验开始分析", ...
                FontSize=10, FontColor=[0.38, 0.43, 0.48], HorizontalAlignment="right");
            layout.StatusLabel.Layout.Row = 2;
            layout.StatusLabel.Layout.Column = [3, 4];
        end

        function controls = sideGrid(~, tab, rows)
            controls = uigridlayout(tab, [rows, 2]);
            controls.RowHeight = repmat({28}, 1, rows);
            controls.Padding = [8, 8, 8, 8];
            controls.RowSpacing = 7;
            controls.Scrollable = "on";
            controls.BackgroundColor = [0.98, 0.98, 0.99];
        end

        function sectionTitle(~, controls, row, textValue)
            label = uilabel(controls, Text=textValue, FontWeight="bold", ...
                FontColor=[0.22, 0.29, 0.36], FontSize=11);
            label.Layout.Row = row;
            label.Layout.Column = [1, 2];
        end

        function parameterLabel(~, controls, row, textValue)
            label = uilabel(controls, Text=textValue, HorizontalAlignment="right", FontSize=11);
            label.Layout.Row = row;
            label.Layout.Column = 1;
        end

        function placeControl(~, control, row)
            control.Layout.Row = row;
            control.Layout.Column = 2;
        end

        function fullRow(~, control, row)
            control.Layout.Row = row;
            control.Layout.Column = [1, 2];
        end
    end
end
