classdef fUSWorkspaceAppV2 < handle
    % fUSWorkspaceAppV2 可运行的 fUS 工作区参考实现。
    %
    % 架构：
    %   1. 本类保存运行状态并协调回调和工作流；
    %   2. fUSWorkspaceLayout 只创建纯 MATLAB uifigure 界面；
    %   3. fus.ImageSequence 负责图像序列和缓存；
    %   4. fus.CBVEngine 负责全部 baseline 和 CBV 数值计算；
    %   5. fus.ExperimentPlan 与 fus.FrameRenderer 分别负责阶段和画面。
    %   6. fUSWorkspaceProjectWorkflow 负责多截面项目和批量处理；
    %   7. fUSWorkspaceProject / fus.ExperimentStore 负责metadata与文件存储。
    %
    % 新算法应进入 core/+fus，不要写进本控制器。参见：
    % docs/如何添加新算法.md

    % ======================== 界面组件 ========================
    properties (Access = {?fUSWorkspaceProjectWorkflow, ?fUSWorkspaceComparisonWorkflow})
        Layout
        UIFigure
        MainGrid
        TabGroup
        BrowserTab
        CBVTab
        ExperimentTab
        ComparisonTab
        ImagePanel
        BrowserAxes
        CBVAxes
        BrowserImage
        TimestampText
        CBVBackgroundImage
        CBVActivityImage
        CBVBackgroundRGB uint8 = []
        CBVBackgroundMode logical = true
        CBVColorBar
        ROIStatusLabel
        ROITable
        ROICurveAxes
        DataFolderLabel
        ResultFolderLabel
        SectionDropDown
        ExperimentStatusLabel
        BodyGrid
        SettingsPanel
        ComparisonGrid
        ViewModeDropDown
        SectionListBox
        CrossROITable
        ShowAllSectionsCheckBox
        ExportStyleDropDown
        ImageToolDropDown
        ROILabelsCheckBox
        ImageFocusButton
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

    % ======================== 数据与运行状态 ========================
    properties (Access = {?fUSWorkspaceProjectWorkflow, ?fUSWorkspaceComparisonWorkflow})
        Sequence
        Files string = strings(0, 1)
        DataFolder string = ""
        DataSourceType string = ""
        ResultFolder string = ""
        CurrentIndex double = 1
        OriginalRatio double = 1
        LockedRatio double = 1
        PlaybackTimer
        PlaybackClock = []
        PlaybackStartIndex double = 1
        Bookmarks table
        ExperimentPlan table
        BaselineGray double = []
        AnalysisMask logical = []
        CurrentCBVMap double = []
        CurrentAverageIndices double = []
        IsBaselineValid logical = false
        IsBusy logical = false
        IsSelectingROI logical = false
        CurrentViewMode string = "browser"
        Baseline struct = struct()
        ROIs struct = struct("Name", {}, "Mask", {}, "NormalizedPosition", {}, "Visible", {})
        ROIOverlayHandles cell = {}
        ROIOverlayListeners cell = {}
        IsUpdatingROIOverlay logical = false
        ROICurveHandles = gobjects(0)
        ROICurvePointHandles = gobjects(0)
        ROICurvePastHandles = gobjects(0)
        ROISelectionViewMode string = "browser"
        UserDisplayMask logical = []
        UserDisplayMaskVertices double = []
        UserDisplayMaskHandle = []
        UserDisplayMaskListeners cell = {}
        IsUpdatingDisplayMask logical = false
        ROISelectedIndex double = 0
        ROICurveTimes double = []
        ROICurveValues double = []
        ROICurveValid logical = false(1, 0)
        ROICurveParameters struct = struct()
        ROICurveFPS double = NaN
        Project = []
        SectionKey string = ""
        SequenceFingerprint struct = struct()
        MetadataTimer
        IsRestoringMetadata logical = false
        IsBatchProcessing logical = false
        MetadataNeedsSave logical = false
        ComparisonSelectedKeys string = strings(0, 1)
        ComparisonCards cell = {}
        ComparisonCache struct = struct("Key", {}, "Sequence", {}, ...
            "Baseline", {}, "Signature", {}, "Fingerprint", {})
        IsUpdatingComparison logical = false
        IsImageFocused logical = false
        IsEditingDisplayMask logical = false
        SidebarBeforeFocus logical = true
        ReportLayout string = "bottom"
        ReportCurveFraction double = 0.26
        ReportFrameSize (1, 2) double = [800, 1280]
        ReportShowROILabels logical = false
    end

    % ======================== 生命周期与公开接口 ========================
    methods
        function app = fUSWorkspaceAppV2(startFolder, options)
            arguments
                startFolder (1, 1) string = ""
                options.RestoreLastProject (1, 1) logical = true
            end
            app.ensureCorePath();
            app.Bookmarks = table([], [], strings(0, 1), strings(0, 1), ...
                VariableNames=["Frame", "Time_s", "File", "Note"]);
            app.ExperimentPlan = app.defaultExperimentPlan();
            app.buildUI();
            app.CurrentViewMode = string(app.ViewModeDropDown.Value);
            app.PlaybackTimer = timer( ...
                ExecutionMode="fixedRate", BusyMode="drop", Period=0.1, ...
                TimerFcn=@(~, ~)app.playbackTick());
            app.UIFigure.CloseRequestFcn = @(~, ~)app.closeApp();
            app.updateConversionControls();
            app.MetadataTimer = timer(ExecutionMode="fixedSpacing", ...
                Period=5, BusyMode="drop", TimerFcn=@(~, ~)app.autosaveMetadata());
            start(app.MetadataTimer);
            if strlength(startFolder) > 0
                app.openExperiment(string(startFolder));
            elseif options.RestoreLastProject && ispref("fUSWorkspace", "LastExperimentRoot")
                lastRoot = string(getpref("fUSWorkspace", "LastExperimentRoot"));
                if isfolder(lastRoot)
                    app.openExperiment(lastRoot);
                else
                    app.ExperimentStatusLabel.Text = ...
                        "上次数据目录未连接；连接硬盘后选择实验根目录即可恢复。";
                end
            end
        end

        function delete(app)
            if ~isempty(app.MetadataTimer) && isvalid(app.MetadataTimer)
                stop(app.MetadataTimer);
                delete(app.MetadataTimer);
            end
            if ~isempty(app.PlaybackTimer) && isvalid(app.PlaybackTimer)
                stop(app.PlaybackTimer);
                delete(app.PlaybackTimer);
            end
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                delete(app.UIFigure);
            end
        end

        function waitForClose(app)
            % Keep a compiled standalone process alive until its UI closes.
            if ~isempty(app.UIFigure) && isvalid(app.UIFigure)
                waitfor(app.UIFigure);
            end
        end

        function figureHandle = getFigure(app)
            % Return the app window so MATLAB Apps Gallery can manage it.
            figureHandle = app.UIFigure;
        end

        function bringToFront(app)
            % 恢复并聚焦现有窗口。Apps页再次启动同一App时复用此入口。
            if isempty(app.UIFigure) || ~isvalid(app.UIFigure)
                return
            end
            app.UIFigure.Visible = "on";
            if app.UIFigure.WindowState == "minimized"
                app.UIFigure.WindowState = "normal";
            end
            drawnow;
            focus(app.UIFigure);
        end

        function openExperiment(app, root, options)
            % 实验打开与恢复由独立工作流负责；保留脚本调用入口。
            arguments
                app
                root (1, 1) string
                options.ProjectFile (1, 1) string = ""
                options.PreferredDataFolder (1, 1) string = ""
            end
            fUSWorkspaceProjectWorkflow.openExperiment(app, root, ...
                ProjectFile=options.ProjectFile, ...
                PreferredDataFolder=options.PreferredDataFolder);
        end

        function report = processExperiment(app, options)
            % 按共用设置处理实验截面；具体过程见 fUSWorkspaceProjectWorkflow。
            arguments
                app
                options.ExportVideos (1, 1) logical = false
                options.ShowProgress (1, 1) logical = true
            end
            report = fUSWorkspaceProjectWorkflow.processExperiment(app, ...
                ExportVideos=options.ExportVideos, ShowProgress=options.ShowProgress);
        end

        function videoExport = batchExportCBVVideo( ...
                app, dataFolder, outputPath, options)
            %BATCHEXPORTCBVVIDEO 使用App当前算法和渲染路径非交互导出CBV视频。
            arguments
                app
                dataFolder (1, 1) string
                outputPath (1, 1) string
                options.ActualFPS (1, 1) double {mustBePositive} = 2
                options.BaselineSeconds (1, 2) double ...
                    {mustBeNonnegative} = [0, 60]
                options.DisplayLimit (1, 1) double {mustBePositive} = 15
                options.Transparency (1, 1) double ...
                    {mustBeGreaterThanOrEqual(options.Transparency, 0), ...
                     mustBeLessThanOrEqual(options.Transparency, 1)} = 0.75
                options.BrainMask (1, 1) logical = true
                options.LowThreshold (1, 1) double {mustBeNonnegative} = 0
                options.ShowBackground (1, 1) logical = true
                options.VideoFrameRate (1, 1) double {mustBePositive} = 10
                options.ExperimentPlanFile (1, 1) string = ""
            end

            if options.BaselineSeconds(2) <= options.BaselineSeconds(1)
                error("fUSWorkspace:InvalidBatchBaseline", ...
                    "baseline结束时间必须晚于开始时间。");
            end
            [outputFolder, ~, extension] = fileparts(outputPath);
            if ~strcmpi(extension, ".mp4")
                error("fUSWorkspace:InvalidBatchVideoPath", ...
                    "批处理输出路径必须使用.mp4扩展名。");
            end
            if strlength(string(outputFolder)) == 0
                error("fUSWorkspace:BatchVideoFolderRequired", ...
                    "批处理输出路径必须包含目录。");
            end
            if isfile(outputPath)
                error("fUSWorkspace:BatchVideoExists", ...
                    "拒绝覆盖现有视频：%s", outputPath);
            end
            if ~isfolder(outputFolder)
                mkdir(outputFolder);
            end

            % 脚本导出不应写回用户上次打开的交互项目。
            app.persistMetadata();
            app.Project = [];
            app.SectionKey = "";
            app.SectionDropDown.Enable = "off";
            app.ExperimentStatusLabel.Text = "脚本导出模式：本次参数不覆盖交互实验项目";

            app.ActualFPSField.Value = options.ActualFPS;
            app.PlaybackFPSField.Value = options.VideoFrameRate;
            app.BaselineStartField.Value = options.BaselineSeconds(1);
            app.BaselineEndField.Value = options.BaselineSeconds(2);
            app.LowThresholdField.Value = options.LowThreshold;
            app.HighThresholdField.Value = options.DisplayLimit;
            app.TransparencySlider.Value = options.Transparency;
            app.ShowBackgroundCheckBox.Value = options.ShowBackground;
            app.BrainMaskCheckBox.Value = options.BrainMask;

            if strlength(options.ExperimentPlanFile) > 0
                if ~isfile(options.ExperimentPlanFile)
                    error("fUSWorkspace:BatchPlanNotFound", ...
                        "实验计划不存在：%s", options.ExperimentPlanFile);
                end
                plan = readtable(options.ExperimentPlanFile, TextType="string");
                app.ExperimentPlan = fus.ExperimentPlan.normalize(plan(:, 1:3));
                app.ExperimentPlanTable.Data = app.ExperimentPlan;
            end

            app.loadDataFolder(dataFolder, "pdi");
            if isempty(app.Files) || app.DataSourceType ~= "pdi"
                error("fUSWorkspace:BatchDataLoadFailed", ...
                    "App未能载入PDI数据：%s", dataFolder);
            end
            if ~app.IsBaselineValid
                error("fUSWorkspace:BatchBaselineFailed", ...
                    "App baseline计算失败：%s", app.StatusLabel.Text);
            end

            app.setResultFolder(string(outputFolder));
            app.CurrentViewMode = "cbv";
            app.refreshCBV();
            videoExport = app.exportVideoToPath(outputPath, ShowProgress=false, Style="image");
        end
    end

    methods (Access = {?fUSWorkspaceProjectWorkflow, ?fUSWorkspaceComparisonWorkflow})
        %% 连接独立布局与行为回调
        function buildUI(app)
            % 界面布局在 fUSWorkspaceLayout 中；本类只提供行为回调。
            callbacks = struct();
            callbacks.chooseDataFolder = @()app.chooseDataFolder();
            callbacks.chooseResultFolder = @()app.chooseResultFolder();
            callbacks.saveWorkspace = @()app.saveWorkspace();
            callbacks.loadWorkspace = @()app.loadWorkspace();
            callbacks.viewTabChanged = @(tab)app.viewTabChanged(tab);
            callbacks.refreshBrowser = @()app.refreshBrowser();
            callbacks.refreshSharedView = @()app.refreshSharedView();
            callbacks.widthChanged = @()app.widthChanged();
            callbacks.heightChanged = @()app.heightChanged();
            callbacks.lockRatioChanged = @()app.lockRatioChanged();
            callbacks.addBookmark = @()app.addBookmark();
            callbacks.deleteBookmark = @()app.deleteBookmark();
            callbacks.saveBookmarks = @()app.saveBookmarks();
            callbacks.exportVideo = @()app.exportVideo();
            callbacks.markBaselineDirty = @()app.markBaselineDirty();
            callbacks.refreshCBV = @()app.refreshCBV();
            callbacks.temporalAverageChanged = @()app.temporalAverageChanged();
            callbacks.conversionChanged = @()app.conversionChanged();
            callbacks.refreshCBVDisplayOnly = @()app.refreshCBVDisplayOnly();
            callbacks.transparencyChanging = @(value)app.transparencyChanging(value);
            callbacks.computeBaseline = @()app.computeCBVAndAllROIs();
            callbacks.saveCurrentCBVResult = @()app.saveCurrentCBVResult();
            callbacks.exportCBVVideo = @()app.exportCBVVideo();
            callbacks.addPolygonROI = @()app.addPolygonROI();
            callbacks.removeSelectedROI = @()app.removeSelectedROI();
            callbacks.roiVisibilityChanged = @(event)app.roiVisibilityChanged(event);
            callbacks.roiSelected = @(event)app.roiSelected(event);
            callbacks.showROICurves = @()app.computeExperimentCurves();
            callbacks.experimentPlanChanged = @()app.experimentPlanChanged();
            callbacks.resetExperimentPlan = @()app.resetExperimentPlan();
            callbacks.loadExperimentPlan = @()app.loadExperimentPlan();
            callbacks.saveExperimentPlan = @()app.saveExperimentPlan();
            callbacks.togglePlayback = @()app.togglePlayback();
            callbacks.sliderMoving = @(value)app.sliderMoving(value);
            callbacks.actualFPSChanged = @()app.actualFPSChanged();
            callbacks.playbackFPSChanged = @()app.playbackFPSChanged();
            callbacks.chooseExperimentFolder = @()app.chooseExperimentFolder();
            callbacks.sectionChanged = @(key)app.activateSection(key);
            callbacks.batchProcessSections = @()app.batchProcessSections();
            callbacks.exportROICurves = @()app.exportROICurves();
            callbacks.metadataChanged = @()app.scheduleMetadataSave();
            callbacks.addExperimentPhase = @()app.addExperimentPhase();
            callbacks.deleteExperimentPhase = @()app.deleteExperimentPhase();
            callbacks.viewModeChanged = @(mode)app.viewModeChanged(mode);
            callbacks.comparisonSelectionChanged = @(keys)app.comparisonSelectionChanged(keys);
            callbacks.toggleSettings = @()app.toggleSettings();
            callbacks.drawDisplayMask = @()app.drawDisplayMask();
            callbacks.clearDisplayMask = @()app.clearDisplayMask();
            callbacks.rebuildComparisonCurves = @()app.renderROICurves();
            callbacks.crossROISelected = @(event)app.crossROISelected(event);
            callbacks.computeExperimentCurves = @()app.computeExperimentCurves();
            callbacks.showComparisonPanel = @()app.showComparisonPanel();
            callbacks.toggleImageFocus = @()app.toggleImageFocus();
            callbacks.imageToolChanged = @(mode)app.imageToolChanged(mode);
            callbacks.zoomImageOut = @()zoom(app.BrowserAxes, 0.8);
            callbacks.resetImageView = @()app.applyAspect();
            callbacks.roiLabelsChanged = @()app.roiLabelsChanged();

            app.Layout = fUSWorkspaceLayout( ...
                callbacks, app.Bookmarks, app.ExperimentPlan, app.appIconPath());
            components = app.Layout.components();
            names = string(fieldnames(components));
            for index = 1:numel(names)
                app.(names(index)) = components.(names(index));
            end
        end

        %% 实验项目工作流入口（实现位于 fUSWorkspaceProjectWorkflow）
        function chooseExperimentFolder(app)
            fUSWorkspaceProjectWorkflow.chooseExperimentFolder(app);
        end

        function succeeded = sectionChanged(app, key)
            succeeded = fUSWorkspaceProjectWorkflow.sectionChanged(app, key);
        end

        function activateSection(app, key)
            if string(key) == app.SectionKey || app.IsBusy || app.IsSelectingROI
                return
            end
            seconds = app.frameTime(app.CurrentIndex);
            if app.sectionChanged(key)
                app.CurrentIndex = min(numel(app.Files), max(1, round(seconds*app.ActualFPSField.Value)));
                app.TimelineSlider.Value = app.CurrentIndex;
                app.refreshAll();
            end
        end

        function restoreSectionState(app, state)
            fUSWorkspaceProjectWorkflow.restoreSectionState(app, state);
        end

        function finishMetadataRestore(app)
            fUSWorkspaceProjectWorkflow.finishMetadataRestore(app);
        end

        function snapshot = captureLiveSnapshot(app)
            snapshot = fUSWorkspaceProjectWorkflow.captureLiveSnapshot(app);
        end

        function restoreLiveSnapshot(app, snapshot)
            fUSWorkspaceProjectWorkflow.restoreLiveSnapshot(app, snapshot);
        end

        function scheduleMetadataSave(app)
            fUSWorkspaceProjectWorkflow.scheduleMetadataSave(app);
        end

        function autosaveMetadata(app)
            fUSWorkspaceProjectWorkflow.autosaveMetadata(app);
        end

        function persistMetadata(app)
            fUSWorkspaceProjectWorkflow.persistMetadata(app);
        end

        function signature = analysisSignature(app)
            signature = fUSWorkspaceProjectWorkflow.analysisSignature(app);
        end

        function updateExperimentStatus(app)
            fUSWorkspaceProjectWorkflow.updateExperimentStatus(app);
        end

        function batchProcessSections(app)
            fUSWorkspaceProjectWorkflow.batchProcessSections(app);
        end

        function proceed = batchProgress(app, progress, index, count, fraction)
            proceed = fUSWorkspaceProjectWorkflow.batchProgress(app, progress, index, count, fraction);
        end

        function finishBatch(app, originalKey, originalMode)
            fUSWorkspaceProjectWorkflow.finishBatch(app, originalKey, originalMode);
        end

        function exportROICurves(app)
            fUSWorkspaceProjectWorkflow.exportROICurves(app);
        end

        function writeROICurves(app, folder)
            fUSWorkspaceProjectWorkflow.writeROICurves(app, folder);
        end

        %% 同一实验的多截面对照与ROI总览
        function comparisonSelectionChanged(app, keys)
            fUSWorkspaceComparisonWorkflow.selectionChanged(app, keys);
        end

        function refreshComparisonFrames(app)
            fUSWorkspaceComparisonWorkflow.refreshFrames(app);
        end

        function updateComparisonControls(app)
            fUSWorkspaceComparisonWorkflow.updateControls(app);
        end

        function refreshCrossROIOverview(app)
            fUSWorkspaceComparisonWorkflow.updateROIOverview(app);
        end

        function specs = crossSectionCurveSpecs(app)
            specs = fUSWorkspaceComparisonWorkflow.curveSpecs(app);
        end

        function colors = roiDisplayColors(app)
            colors = zeros(numel(app.ROIs), 3);
            for index = 1:numel(app.ROIs)
                colors(index, :) = fUSWorkspaceComparisonWorkflow.roiColor(app.SectionKey, index);
            end
        end

        function computeExperimentCurves(app)
            if app.IsBusy || app.IsBatchProcessing || app.IsSelectingROI
                return
            end
            if isempty(app.Project)
                if ~isempty(app.ROIs)
                    app.showROICurves();
                end
                return
            end
            keys = app.ComparisonSelectedKeys;
            xLimits = app.BrowserAxes.XLim;
            yLimits = app.BrowserAxes.YLim;
            cleanup = onCleanup(@()app.restoreROIUpdateView(keys, xLimits, yLimits));
            try
                fUSWorkspaceProjectWorkflow.processExperiment(app, CacheOnly=true, ...
                    ShowProgress=app.UIFigure.Visible == "on");
            catch errorInfo
                app.StatusLabel.Text = "ROI总览更新失败：" + string(errorInfo.message);
                if app.UIFigure.Visible == "on"
                    uialert(app.UIFigure, string(errorInfo.message), "ROI更新未完成");
                else
                    warning("fUS:ROIUpdateFailed", "%s", errorInfo.message);
                end
            end
            clear cleanup
            app.renderROICurves();
            app.refreshCrossROIOverview();
        end

        function restoreROIUpdateView(app, keys, xLimits, yLimits)
            app.ComparisonSelectedKeys = keys;
            app.updateComparisonControls();
            app.BrowserAxes.XLim = xLimits;
            app.BrowserAxes.YLim = yLimits;
            app.persistMetadata();
        end

        function showComparisonPanel(app)
            if app.IsImageFocused
                app.toggleImageFocus();
            end
            app.SettingsPanel.Visible = "on";
            app.BodyGrid.ColumnWidth = {"1x", 320};
            app.TabGroup.SelectedTab = app.ComparisonTab;
        end

        function crossROISelected(app, event)
            fUSWorkspaceComparisonWorkflow.roiSelected(app, event);
        end

        function crossCurveClicked(app, key, index, event)
            fUSWorkspaceComparisonWorkflow.curveClicked(app, key, index, event);
        end

        function toggleSettings(app)
            showing = app.SettingsPanel.Visible == "on";
            app.SettingsPanel.Visible = matlab.lang.OnOffSwitchState(~showing);
            if showing
                app.BodyGrid.ColumnWidth = {"1x", 0};
            else
                app.BodyGrid.ColumnWidth = {"1x", 320};
            end
            app.scheduleMetadataSave();
        end

        function toggleImageFocus(app)
            if app.IsBusy || app.IsSelectingROI
                return
            end
            workspace = app.ComparisonGrid.Parent;
            curvePanel = app.ROICurveAxes.Parent.Parent;
            if app.IsImageFocused
                workspace.RowHeight = {28, "2.7x", "1x"};
                curvePanel.Visible = "on";
                if app.SidebarBeforeFocus
                    app.SettingsPanel.Visible = "on";
                    app.BodyGrid.ColumnWidth = {"1x", 320};
                end
            else
                app.SidebarBeforeFocus = app.SettingsPanel.Visible == "on";
                app.SettingsPanel.Visible = "off";
                app.BodyGrid.ColumnWidth = {"1x", 0};
                curvePanel.Visible = "off";
                workspace.RowHeight = {28, "1x", 0};
            end
            app.IsImageFocused = ~app.IsImageFocused;
            if app.IsImageFocused
                app.ImageFocusButton.Text = "恢复对照";
            else
                app.ImageFocusButton.Text = "放大标注";
            end
            app.refreshComparisonFrames();
        end

        function imageToolChanged(app, mode)
            zoom(app.BrowserAxes, "off");
            pan(app.BrowserAxes, "off");
            if string(mode) == "zoom"
                zoom(app.BrowserAxes, "on");
            elseif string(mode) == "pan"
                pan(app.BrowserAxes, "on");
            else
                app.BrowserAxes.Interactions = zoomInteraction;
            end
            editing = string(mode) == "edit" && ~app.IsBusy;
            for index = 1:numel(app.ROIOverlayHandles)
                polygon = app.ROIOverlayHandles{index};
                if isvalid(polygon)
                    if editing
                        polygon.InteractionsAllowed = "all";
                    else
                        polygon.InteractionsAllowed = "none";
                    end
                end
            end
        end

        function roiLabelsChanged(app)
            app.drawROIOverlays();
            app.scheduleMetadataSave();
        end

        function viewModeChanged(app, mode)
            if app.IsBusy || app.IsBatchProcessing
                app.ViewModeDropDown.Value = app.CurrentViewMode;
                return
            end
            app.CurrentViewMode = string(mode);
            app.ViewModeDropDown.Value = app.CurrentViewMode;
            app.refreshAll();
            app.scheduleMetadataSave();
        end

        %% 实验计划与阶段时间戳
        function plan = defaultExperimentPlan(~)
            plan = fus.ExperimentPlan.defaultPlan();
        end

        function plan = currentExperimentPlan(app)
            if ~isempty(app.ExperimentPlanTable) && isvalid(app.ExperimentPlanTable)
                plan = app.ExperimentPlanTable.Data;
            else
                plan = app.ExperimentPlan;
            end
            plan = fus.ExperimentPlan.normalize(plan);
        end

        function phase = phaseForTime(app, seconds)
            try
                phase = fus.ExperimentPlan.phaseAtNormalized( ...
                    app.ExperimentPlan, seconds);
            catch
                phase = "计划格式错误";
            end
        end

        function experimentPlanChanged(app)
            try
                app.ExperimentPlan = app.currentExperimentPlan();
                app.ExperimentPlanTable.Data = app.ExperimentPlan;
                app.refreshSharedView();
                app.renderROICurves();
                app.updateFrameLabel();
                app.StatusLabel.Text = "实验计划已更新；时间戳将自动使用新阶段";
            catch errorInfo
                uialert(app.UIFigure, string(errorInfo.message), "实验计划格式错误");
            end
        end

        function resetExperimentPlan(app)
            app.ExperimentPlan = app.defaultExperimentPlan();
            app.ExperimentPlanTable.Data = app.ExperimentPlan;
            app.refreshSharedView();
            app.renderROICurves();
            app.updateFrameLabel();
            app.StatusLabel.Text = "已恢复默认后爪实验计划";
            app.scheduleMetadataSave();
        end

        function addExperimentPhase(app)
            plan = app.currentExperimentPlan();
            startTime = 0;
            if ~isempty(plan)
                startTime = max(plan.End_s);
            end
            plan = [plan; table(startTime, startTime+30, "新阶段", ...
                VariableNames=["Start_s", "End_s", "Label"])];
            app.ExperimentPlanTable.Data = plan;
            app.experimentPlanChanged();
        end

        function deleteExperimentPhase(app)
            selected = app.ExperimentPlanTable.Selection;
            if isempty(selected)
                return
            end
            plan = app.currentExperimentPlan();
            plan(unique(selected(:, 1)), :) = [];
            app.ExperimentPlanTable.Data = plan;
            app.experimentPlanChanged();
        end

        function loadExperimentPlan(app)
            [fileName, folder] = uigetfile("*.csv", "载入实验计划CSV");
            if isequal(fileName, 0)
                return
            end
            try
                plan = readtable(fullfile(folder, fileName), TextType="string");
                if width(plan) < 3
                    error("fUS:InvalidExperimentPlan", "CSV至少需要三列：开始、结束、阶段。");
                end
                plan = fus.ExperimentPlan.normalize(plan(:, 1:3));
                app.ExperimentPlan = plan;
                app.ExperimentPlanTable.Data = plan;
                app.experimentPlanChanged();
            catch errorInfo
                uialert(app.UIFigure, string(errorInfo.message), "实验计划载入失败");
            end
        end

        function saveExperimentPlan(app)
            app.ensureResultFolder();
            plan = app.currentExperimentPlan();
            outputPath = fullfile(app.ResultFolder, "fUS实验计划.csv");
            writetable(plan, outputPath, Encoding="UTF-8");
            app.StatusLabel.Text = "实验计划已保存：" + outputPath;
        end

        function updateTimestampOverlay(app)
            if isempty(app.TimestampText) || ~isvalid(app.TimestampText)
                return
            end
            if app.TimestampCheckBox.Value
                app.TimestampText.String = app.timeLabel(app.CurrentIndex);
                app.TimestampText.Position = [ ...
                    0.02*app.WidthField.Value, 0.02*app.HeightField.Value, 10];
                app.TimestampText.Visible = "on";
            else
                app.TimestampText.Visible = "off";
            end
        end

        %% 数据与结果文件夹
        function chooseDataFolder(app)
            folder = uigetdir(pwd, "选择实验文件夹或SVD数据文件夹");
            if isequal(folder, 0)
                return
            end
            % 单截面入口也寻找上层实验项目，使原始数据与metadata重新关联。
            root = string(folder);
            candidate = root;
            for level = 1:6
                if isfile(fus.ExperimentStore.projectPath(candidate))
                    root = candidate;
                    break
                end
                parent = string(fileparts(candidate));
                if parent == candidate || strlength(parent) == 0
                    break
                end
                candidate = parent;
            end
            app.openExperiment(root, PreferredDataFolder=string(folder));
        end

        function loaded = loadDataFolder(app, folder, sourceType, preserveImageSettings, computeNow)
            loaded = false;
            if nargin < 3 || strlength(string(sourceType)) == 0
                sourceType = app.chooseDataSourceType(folder);
            end
            if nargin < 4
                preserveImageSettings = false;
            end
            if nargin < 5
                computeNow = true;
            end
            sourceType = string(sourceType);
            if strlength(sourceType) == 0
                return
            end
            app.stopPlayback();
            app.StatusLabel.Text = "正在扫描共享数据...";
            drawnow;
            try
                switch sourceType
                    case "pdi"
                        sequence = fus.PDISequence(folder, MaxCacheFrames=24);
                    case "image"
                        sequence = fus.ImageSequence(folder, MaxCacheFrames=24);
                    otherwise
                        error("fUS:InvalidDataSource", "不支持的数据源：%s", sourceType);
                end
                % 验证首帧可读取后再替换当前状态，失败时保留正在查看的截面。
                firstFrame = sequence.readFrame(1);
            catch errorInfo
                if app.IsRestoringMetadata || app.IsBatchProcessing
                    rethrow(errorInfo);
                end
                uialert(app.UIFigure, string(errorInfo.message), "无法载入数据");
                app.StatusLabel.Text = "数据载入失败";
                return
            end

            previousSourceType = app.DataSourceType;
            app.Sequence = sequence;
            app.Files = sequence.Files;
            app.DataFolder = sequence.Folder;
            app.DataSourceType = sequence.SourceType;
            app.configureDataSource(previousSourceType, preserveImageSettings);
            app.CurrentIndex = 1;
            app.clearCache();
            app.clearROIs();
            app.Bookmarks = app.Bookmarks([], :);
            app.BookmarkTable.Data = app.Bookmarks;
            app.IsBaselineValid = false;
            app.ExportCBVVideoButton.Enable = "off";
            app.CurrentCBVMap = [];
            app.CBVBackgroundRGB = [];
            app.UserDisplayMask = [];
            app.UserDisplayMaskVertices = [];
            app.drawDisplayMaskOverlay();

            app.Baseline = struct();
            app.BaselineGray = [];
            app.AnalysisMask = [];
            app.SaveCBVButton.Enable = "off";
            [height, width, ~] = size(firstFrame);
            app.WidthField.Value = width;
            app.HeightField.Value = height;
            app.OriginalRatio = width/height;
            app.LockedRatio = app.OriginalRatio;
            app.applyAspect();
            app.TimelineSlider.Limits = [1, max(2, sequence.frameCount())];
            app.TimelineSlider.Value = 1;
            app.TimelineSlider.Enable = "on";
            app.PlayButton.Enable = matlab.lang.OnOffSwitchState( ...
                sequence.frameCount() > 1);
            app.ComputeBaselineButton.Enable = "on";

            [~, folderName] = fileparts(fileparts(app.DataFolder));
            if app.DataSourceType == "pdi"
                sourceLabel = "PDI线性数据";
            else
                sourceLabel = "BMP/PNG图像";
            end
            app.DataFolderLabel.Text = sprintf("%s · %s · %d帧", ...
                folderName, sourceLabel, sequence.frameCount());
            if strlength(app.ResultFolder) == 0
                app.setResultFolder(fullfile( ...
                    fileparts(app.DataFolder), "fUS工作区结果"));
            end
            app.refreshBrowser();
            loaded = true;
            if computeNow
                app.StatusLabel.Text = "数据已载入；正在计算CBV baseline...";
                app.computeBaseline();
            end
        end

        function sourceType = chooseDataSourceType(app, folder)
            hasPdi = fus.PDISequence.isAvailable(folder);
            hasImages = fus.ImageSequence.isAvailable(folder);
            if hasPdi && hasImages
                choice = uiconfirm(app.UIFigure, ...
                    "检测到同一序列的PDI和BMP/PNG。请选择本次分析的数据源。", ...
                    "选择数据源", ...
                    Options=["PDI（推荐，线性定量）", "BMP/PNG（显示图）", "取消"], ...
                    DefaultOption=1, CancelOption=3, Icon="question");
                switch choice
                    case "PDI（推荐，线性定量）"
                        sourceType = "pdi";
                    case "BMP/PNG（显示图）"
                        sourceType = "image";
                    otherwise
                        sourceType = "";
                end
            elseif hasPdi
                sourceType = "pdi";
            elseif hasImages
                sourceType = "image";
            else
                sourceType = "image";
            end
        end

        function configureDataSource(app, previousSourceType, preserveImageSettings)
            if app.DataSourceType == "pdi"
                app.ConversionDropDown.Value = "linear";
                app.ConversionDropDown.Enable = "off";
                app.MinimumBaselineField.Value = eps;
                app.MinimumBaselineField.Enable = "off";
            else
                app.ConversionDropDown.Enable = "on";
                app.MinimumBaselineField.Enable = "on";
                if ~preserveImageSettings && previousSourceType == "pdi"
                    app.ConversionDropDown.Value = "unknown";
                    app.MinimumBaselineField.Value = 35;
                end
            end
            app.updateConversionControls();
        end

        function chooseResultFolder(app)
            startPath = pwd;
            if strlength(app.ResultFolder) > 0 && isfolder(app.ResultFolder)
                startPath = app.ResultFolder;
            end
            folder = uigetdir(startPath, "选择共享结果文件夹");
            if isequal(folder, 0)
                return
            end
            if ~isempty(app.Project)
                app.Project.setResultRoot(string(folder));
                app.setResultFolder(app.Project.resultFolder(app.SectionKey));
                app.persistMetadata();
            else
                app.setResultFolder(string(folder));
            end
        end

        function setResultFolder(app, folder)
            if ~isfolder(folder)
                mkdir(folder);
            end
            app.ResultFolder = folder;
            app.ResultFolderLabel.Text = app.compactPath(folder);
        end

        %% 共享画面刷新
        function refreshAll(app)
            app.refreshSharedView();
            app.updateFrameLabel();
            app.updateROICurveCursor();
            app.refreshComparisonFrames();
        end

        function refreshSharedView(app)
            if app.CurrentViewMode == "cbv"
                app.refreshCBV();
            else
                app.refreshBrowser();
            end
        end

        function viewTabChanged(app, selectedTab)
            % 设置页签只组织参数；图像类型由顶部显示切换独立控制。
            if selectedTab == app.CBVTab || selectedTab == app.BrowserTab
                app.refreshAll();
            end
        end

        function refreshBrowser(app)
            if isempty(app.Files) || app.IsSelectingROI
                return
            end
            try
                frame = app.readFrame(app.CurrentIndex);
                shown = app.colorizeFrame(frame, string(app.BrowserColormapDropDown.Value));
                if isempty(app.BrowserImage) || ~isvalid(app.BrowserImage)
                    wasHeld = ishold(app.BrowserAxes);
                    hold(app.BrowserAxes, "on");
                    app.BrowserImage = image(app.BrowserAxes, CData=shown);
                    if ~wasHeld
                        hold(app.BrowserAxes, "off");
                    end
                    app.applyAspect();
                else
                    app.BrowserImage.CData = shown;
                end
                app.BrowserImage.Visible = "on";
                if ~isempty(app.CBVBackgroundImage) && isvalid(app.CBVBackgroundImage)
                    app.CBVBackgroundImage.Visible = "off";
                end
                if ~isempty(app.CBVActivityImage) && isvalid(app.CBVActivityImage)
                    app.CBVActivityImage.Visible = "off";
                end
                if isempty(app.TimestampText) || ~isvalid(app.TimestampText)
                    app.TimestampText = text(app.BrowserAxes, 0, 0, "", ...
                        Color="w", FontWeight="bold", BackgroundColor="k", ...
                        Margin=4, VerticalAlignment="top", Interpreter="none");
                end
                app.CBVColorBar.Visible = "off";
                app.updateTimestampOverlay();
                drawnow limitrate nocallbacks;
            catch errorInfo
                app.StatusLabel.Text = "原图读取失败：" + string(errorInfo.message);
            end
        end

        %% 原图多边形 ROI 与主窗口 CBV 时间曲线
        function addPolygonROI(app)
            if isempty(app.Files) || app.IsBusy
                uialert(app.UIFigure, "请先载入数据并等待当前计算结束。", "无法添加ROI");
                return
            end
            app.stopPlayback();
            app.ImageToolDropDown.Value = "edit";
            app.imageToolChanged("edit");
            app.ROISelectionViewMode = app.CurrentViewMode;
            app.CurrentViewMode = "browser";
            app.refreshBrowser();
            app.StatusLabel.Text = "在原图上点击多边形顶点，双击结束；按 Esc 取消。";
            app.IsSelectingROI = true;
            selectionCleanup = onCleanup(@()app.finishROISelection());
            roi = [];
            try
                roiIndex = numel(app.ROIs) + 1;
                while any(strcmp({app.ROIs.Name}, sprintf("ROI %d", roiIndex)))
                    roiIndex = roiIndex + 1;
                end
                colors = lines(max(7, roiIndex));
                roi = drawpolygon(app.BrowserAxes, ...
                    Color=colors(roiIndex, :), LineWidth=1, FaceAlpha=0);
                if ~isvalid(roi)
                    return
                end
                position = roi.Position;
                if size(position, 1) < 3
                    delete(roi);
                    app.StatusLabel.Text = "已取消ROI绘制";
                    return
                end
                imageSize = size(app.BrowserImage.CData);
                mask = fus.ROIEngine.polygonMask( ...
                    position, imageSize(1:2), ...
                    [app.WidthField.Value, app.HeightField.Value]);
                delete(roi);
                if ~any(mask(:))
                    app.StatusLabel.Text = "ROI为空；请重新绘制。";
                    return
                end
                normalizedPosition = position ./ ...
                    [app.WidthField.Value, app.HeightField.Value];
                app.ROIs(end + 1) = struct( ...
                    Name=sprintf("ROI %d", roiIndex), ...
                    Mask=logical(mask), ...
                    NormalizedPosition=normalizedPosition, Visible=true);
                app.ROICurveValid(end + 1) = false;
                if ~isempty(app.ROICurveValues)
                    app.ROICurveValues(:, end + 1) = NaN;
                end
                app.ROISelectedIndex = numel(app.ROIs);
                app.updateROIStatus();
                app.drawROIOverlays();
                app.renderROICurves();
                app.scheduleMetadataSave();
                app.StatusLabel.Text = sprintf("已添加 ROI %d（%d 像素）", ...
                    roiIndex, nnz(mask));
            catch errorInfo
                app.deleteIfValid(roi);
                uialert(app.UIFigure, string(errorInfo.message), "ROI绘制失败");
            end
            clear selectionCleanup
        end

        function finishROISelection(app)
            app.IsSelectingROI = false;
            app.CurrentViewMode = app.ROISelectionViewMode;
            if isprop(app, "ViewModeDropDown") && ~isempty(app.ViewModeDropDown)
                app.ViewModeDropDown.Value = app.CurrentViewMode;
            end
            app.refreshSharedView();
        end

        function removeSelectedROI(app)
            index = app.ROISelectedIndex;
            if isempty(app.ROIs) || app.IsBusy || index < 1 ...
                    || index > numel(app.ROIs)
                app.StatusLabel.Text = "请先在ROI列表中选中要删除的行";
                return
            end
            removedName = app.ROIs(index).Name;
            app.ROIs(index) = [];
            if index <= numel(app.ROICurveValid)
                app.ROICurveValid(index) = [];
            end
            if ~isempty(app.ROICurveValues)
                app.ROICurveValues(:, index) = [];
            end
            app.ROISelectedIndex = 0;
            app.updateROIStatus();
            app.drawROIOverlays();
            app.renderROICurves();
            app.scheduleMetadataSave();
            app.StatusLabel.Text = sprintf("已删除 %s；当前保留 %d 个 ROI", ...
                removedName, numel(app.ROIs));
        end

        function clearROIs(app)
            app.ROIs = struct("Name", {}, "Mask", {}, "NormalizedPosition", {}, "Visible", {});
            app.ROISelectedIndex = 0;
            app.resetROICurveCache();
            app.drawROIOverlays();
            app.updateROIStatus();
        end

        function updateROIStatus(app)
            if ~isempty(app.ROIStatusLabel) && isvalid(app.ROIStatusLabel)
                app.ROIStatusLabel.Text = sprintf("ROI: %d", numel(app.ROIs));
            end
            if ~isempty(app.ROITable) && isvalid(app.ROITable)
                if isempty(app.ROIs)
                    app.ROITable.Data = table(false(0, 1), strings(0, 1), ...
                        zeros(0, 1), VariableNames=["Visible", "ROI", "Pixels"]);
                else
                    app.ROITable.Data = table( ...
                        logical([app.ROIs.Visible])', string({app.ROIs.Name})', ...
                        arrayfun(@(roi)nnz(roi.Mask), app.ROIs)', ...
                        VariableNames=["Visible", "ROI", "Pixels"]);
                end
            end
        end

        function roiSelected(app, event)
            if isempty(event.Indices)
                app.selectROI(0);
            else
                app.selectROI(event.Indices(1, 1));
            end
        end

        function roiVisibilityChanged(app, event)
            if isempty(event.Indices)
                return
            end
            index = event.Indices(1, 1);
            if index < 1 || index > numel(app.ROIs)
                return
            end
            if event.Indices(1, 2) == 1
                app.ROIs(index).Visible = logical(event.NewData);
            elseif event.Indices(1, 2) == 2
                name = strtrim(string(event.NewData));
                if ismissing(name) || strlength(name) == 0
                    app.updateROIStatus();
                    app.StatusLabel.Text = "ROI名称不能为空";
                    return
                end
                app.ROIs(index).Name = char(name);
            else
                return
            end
            app.ROISelectedIndex = index;
            app.updateROIStatus();
            app.drawROIOverlays();
            app.renderROICurves();
            app.scheduleMetadataSave();
        end

        function selectROI(app, index)
            if index < 1 || index > numel(app.ROIs)
                index = 0;
            end
            app.ROISelectedIndex = index;
            app.IsEditingDisplayMask = false;
            app.drawDisplayMaskOverlay();
            app.drawROIOverlays();
            for curveIndex = 1:numel(app.ROICurveHandles)
                curve = app.ROICurveHandles(curveIndex);
                if isgraphics(curve)
                    isSelected = isnumeric(curve.UserData) && isscalar(curve.UserData) ...
                        && curve.UserData == index;
                    curve.LineWidth = 1.6 + 1.6*isSelected;
                    if curveIndex <= numel(app.ROICurvePastHandles) ...
                            && isgraphics(app.ROICurvePastHandles(curveIndex))
                        app.ROICurvePastHandles(curveIndex).LineWidth = 2.1 + isSelected;
                        app.ROICurvePointHandles(curveIndex).MarkerSize = 8 + 2*isSelected;
                    end
                end
            end
            if index > 0 && isprop(app.ROITable, "Selection")
                app.ROITable.Selection = [index, 2];
            end
        end

        function roiGeometryChanged(app, index, polygon)
            if app.IsUpdatingROIOverlay || app.IsSelectingROI ...
                    || index > numel(app.ROIs) || ~isvalid(polygon)
                return
            end
            if app.IsBusy
                app.drawROIOverlays();
                app.StatusLabel.Text = "计算期间不能修改ROI，请等待计算结束";
                return
            end
            position = polygon.Position;
            canvasSize = [app.WidthField.Value, app.HeightField.Value];
            mask = fus.ROIEngine.polygonMask(position, ...
                size(app.ROIs(index).Mask), canvasSize);
            if ~any(mask(:))
                app.drawROIOverlays();
                app.StatusLabel.Text = "ROI必须包含图像像素，已恢复原位置";
                return
            end
            app.ROIs(index).Mask = mask;
            app.ROIs(index).NormalizedPosition = position ./ canvasSize;
            app.ROICurveValid(index) = false;
            if ~isempty(app.ROICurveValues)
                app.ROICurveValues(:, index) = NaN;
            end
            app.ROISelectedIndex = index;
            app.updateROIStatus();
            app.drawROIOverlays();
            app.renderROICurves();
            app.scheduleMetadataSave();
            app.StatusLabel.Text = string(app.ROIs(index).Name) ...
                + " 已修改；点击更新全部ROI曲线，将统一更新项目ROI总览";
        end

        function roiCurveClicked(app, index, event)
            if app.IsBusy || isempty(app.Files)
                return
            end
            app.stopPlayback();
            if (isstruct(event) && isfield(event, "IntersectionPoint")) ...
                    || (isobject(event) && isprop(event, "IntersectionPoint"))
                seconds = event.IntersectionPoint(1);
            else
                point = app.ROICurveAxes.CurrentPoint;
                seconds = point(1, 1);
            end
            app.selectROI(index);
            % 与 frameTime 的采集块结束时间约定保持一致。
            app.sliderMoving(round(seconds*app.ActualFPSField.Value));
            app.updateROICurveCursor();
            app.scheduleMetadataSave();
        end

        function drawROIOverlays(app)
            if app.IsUpdatingROIOverlay
                return
            end
            app.IsUpdatingROIOverlay = true;
            updateCleanup = onCleanup(@()app.finishROIOverlayUpdate());
            if isempty(app.ROIs) || isempty(app.Files) ...
                    || isempty(app.BrowserAxes) || ~isvalid(app.BrowserAxes)
                for index = 1:numel(app.ROIOverlayHandles)
                    app.deleteIfValid(app.ROIOverlayHandles{index});
                end
                app.ROIOverlayHandles = {};
                app.ROIOverlayListeners = {};
                return
            end
            canReuse = numel(app.ROIOverlayHandles) == numel(app.ROIs);
            if canReuse
                canReuse = all(cellfun(@(handle)isvalid(handle), ...
                    app.ROIOverlayHandles));
            end
            if ~canReuse
                for index = 1:numel(app.ROIOverlayHandles)
                    app.deleteIfValid(app.ROIOverlayHandles{index});
                end
                app.ROIOverlayHandles = cell(1, numel(app.ROIs));
                app.ROIOverlayListeners = cell(numel(app.ROIs), 4);
            end
            colors = app.roiDisplayColors();
            wasHeld = ishold(app.BrowserAxes);
            hold(app.BrowserAxes, "on");
            for index = 1:numel(app.ROIs)
                vertices = app.ROIs(index).NormalizedPosition .* ...
                    [app.WidthField.Value, app.HeightField.Value];
                if canReuse
                    polygon = app.ROIOverlayHandles{index};
                    polygon.Position = vertices;
                else
                    polygon = drawpolygon(app.BrowserAxes, Position=vertices, ...
                        Color=colors(index, :), LineWidth=1.5, FaceAlpha=0, ...
                        Deletable=false);
                    app.ROIOverlayHandles{index} = polygon;
                    app.ROIOverlayListeners{index, 1} = addlistener(polygon, ...
                        "ROIMoved", @(source, ~)app.roiGeometryChanged(index, source));
                    app.ROIOverlayListeners{index, 2} = addlistener(polygon, ...
                        "ROIClicked", @(~, ~)app.selectROI(index));
                    app.ROIOverlayListeners{index, 3} = addlistener(polygon, ...
                        "VertexAdded", @(source, ~)app.roiGeometryChanged(index, source));
                    app.ROIOverlayListeners{index, 4} = addlistener(polygon, ...
                        "VertexDeleted", @(source, ~)app.roiGeometryChanged(index, source));
                end
                polygon.Label = app.ROIs(index).Name;
                if app.ROILabelsCheckBox.Value
                    polygon.LabelVisible = "on";
                else
                    polygon.LabelVisible = "off";
                end
                polygon.MarkerSize = 3;
                polygon.FaceAlpha = 0;
                polygon.Color = colors(index, :);
                polygon.Selected = index == app.ROISelectedIndex;
                polygon.LineWidth = 0.65 + 0.45*(index == app.ROISelectedIndex);
                polygon.Visible = matlab.lang.OnOffSwitchState(app.ROIs(index).Visible);
                if app.IsBusy || string(app.ImageToolDropDown.Value) ~= "edit"
                    polygon.InteractionsAllowed = "none";
                else
                    polygon.InteractionsAllowed = "all";
                end
                uistack(polygon, "top");
            end
            if ~wasHeld
                hold(app.BrowserAxes, "off");
            end
            if ~isempty(app.TimestampText) && isvalid(app.TimestampText)
                uistack(app.TimestampText, "top");
            end
        end

        function finishROIOverlayUpdate(app)
            app.IsUpdatingROIOverlay = false;
        end

        function drawDisplayMask(app)
            if isempty(app.Files) || app.IsBusy || app.IsSelectingROI
                app.StatusLabel.Text = "请先载入截面并等待当前处理结束";
                return
            end
            app.stopPlayback();
            app.ImageToolDropDown.Value = "edit";
            app.imageToolChanged("edit");
            app.ROISelectionViewMode = app.CurrentViewMode;
            app.CurrentViewMode = "browser";
            app.refreshBrowser();
            app.IsSelectingROI = true;
            cleanup = onCleanup(@()app.finishROISelection());
            polygon = [];
            try
                app.StatusLabel.Text = "沿需要显示活动的区域绘制多边形，双击结束。区域外保留灰度背景。";
                polygon = drawpolygon(app.BrowserAxes, Color=[0.88, 0.88, 0.88], ...
                    FaceAlpha=0, LineWidth=1.4);
                if ~isvalid(polygon) || size(polygon.Position, 1) < 3
                    app.deleteIfValid(polygon);
                    return
                end
                frame = app.readFrame(1);
                imageSize = size(frame);
                canvasSize = [app.WidthField.Value, app.HeightField.Value];
                mask = fus.ROIEngine.polygonMask( ...
                    polygon.Position, imageSize(1:2), canvasSize);
                if ~any(mask(:))
                    app.deleteIfValid(polygon);
                    app.StatusLabel.Text = "显示区域没有包含图像像素，已保留原区域";
                    return
                end
                app.UserDisplayMask = mask;
                app.UserDisplayMaskVertices = polygon.Position ./ canvasSize;
                app.deleteIfValid(polygon);
                app.BrainMaskCheckBox.Value = true;
                app.drawDisplayMaskOverlay();
                app.scheduleMetadataSave();
                app.StatusLabel.Text = "手绘显示区域已应用；定量ROI和曲线计算不受影响";
            catch errorInfo
                app.deleteIfValid(polygon);
                uialert(app.UIFigure, string(errorInfo.message), "显示区域绘制失败");
            end
            clear cleanup
        end

        function clearDisplayMask(app)
            if app.IsBusy || app.IsSelectingROI
                return
            end
            app.UserDisplayMask = [];
            app.UserDisplayMaskVertices = [];
            app.IsEditingDisplayMask = false;
            app.BrainMaskCheckBox.Value = false;
            app.drawDisplayMaskOverlay();
            app.refreshSharedView();
            app.scheduleMetadataSave();
            app.StatusLabel.Text = "已清除手绘显示区域，活动叠加显示全部有效像素";
        end

        function drawDisplayMaskOverlay(app)
            if app.IsUpdatingDisplayMask
                return
            end
            app.IsUpdatingDisplayMask = true;
            cleanup = onCleanup(@()app.finishDisplayMaskUpdate());
            if isempty(app.UserDisplayMaskVertices) || isempty(app.Files)
                app.deleteIfValid(app.UserDisplayMaskHandle);
                app.UserDisplayMaskHandle = [];
                app.UserDisplayMaskListeners = {};
                return
            end
            vertices = app.UserDisplayMaskVertices .* ...
                [app.WidthField.Value, app.HeightField.Value];
            if isempty(app.UserDisplayMaskHandle) || ~isvalid(app.UserDisplayMaskHandle)
                wasHeld = ishold(app.BrowserAxes);
                hold(app.BrowserAxes, "on");
                polygon = drawpolygon(app.BrowserAxes, Position=vertices, ...
                    Color=[0.88, 0.88, 0.88], FaceAlpha=0, LineWidth=1.3, ...
                    Deletable=false, Label="", LabelVisible="off", ...
                    MarkerSize=1, FaceSelectable=false);
                if ~wasHeld
                    hold(app.BrowserAxes, "off");
                end
                app.UserDisplayMaskHandle = polygon;
                names = ["ROIMoved", "VertexAdded", "VertexDeleted"];
                app.UserDisplayMaskListeners = cell(1, numel(names));
                for index = 1:numel(names)
                    app.UserDisplayMaskListeners{index} = addlistener(polygon, names(index), ...
                        @(source, ~)app.userMaskGeometryChanged(source));
                end
                app.UserDisplayMaskListeners{end + 1} = addlistener(polygon, ...
                    "ROIClicked", @(~, ~)app.editDisplayMask());
            else
                polygon = app.UserDisplayMaskHandle;
                polygon.Position = vertices;
            end
            polygon.Visible = matlab.lang.OnOffSwitchState(app.BrainMaskCheckBox.Value);
            polygon.FaceAlpha = 0;
            polygon.Selected = app.IsEditingDisplayMask;
            polygon.MarkerSize = 1 + 4*app.IsEditingDisplayMask;
            if app.IsBusy
                polygon.InteractionsAllowed = "none";
            else
                polygon.InteractionsAllowed = "all";
            end
            uistack(polygon, "top");
            clear cleanup
        end

        function editDisplayMask(app)
            if app.IsBusy || app.IsSelectingROI
                return
            end
            app.stopPlayback();
            app.IsEditingDisplayMask = true;
            app.drawDisplayMaskOverlay();
            app.StatusLabel.Text = "显示掩膜编辑中：拖动顶点；点击ROI或播放结束编辑";
        end

        function finishDisplayMaskUpdate(app)
            app.IsUpdatingDisplayMask = false;
        end

        function userMaskGeometryChanged(app, polygon)
            if app.IsUpdatingDisplayMask || app.IsSelectingROI
                return
            end
            if app.IsBusy
                app.drawDisplayMaskOverlay();
                return
            end
            canvasSize = [app.WidthField.Value, app.HeightField.Value];
            mask = fus.ROIEngine.polygonMask(polygon.Position, ...
                size(app.UserDisplayMask), canvasSize);
            if ~any(mask(:))
                app.drawDisplayMaskOverlay();
                app.StatusLabel.Text = "显示区域必须包含至少一个图像像素，已恢复原位置";
                return
            end
            app.UserDisplayMask = mask;
            app.UserDisplayMaskVertices = polygon.Position ./ canvasSize;
            app.refreshCBVDisplayOnly();
            app.scheduleMetadataSave();
        end

        function showROICurves(app)
            if isempty(app.ROIs)
                uialert(app.UIFigure, "请先在原图上添加至少一个多边形ROI。", "没有ROI");
                return
            end
            if ~app.IsBaselineValid || app.IsBusy
                uialert(app.UIFigure, "请先按当前参数计算baseline。", "CBV尚未就绪");
                return
            end
            parameters = app.cbvParameters();
            actualFPS = app.ActualFPSField.Value;
            if ~isequaln(app.ROICurveParameters, parameters) ...
                    || app.ROICurveFPS ~= actualFPS
                app.resetROICurveCache();
            end
            pending = find(~app.ROICurveValid);
            if isempty(pending)
                app.renderROICurves();
                app.StatusLabel.Text = "ROI曲线已是最新结果";
                return
            end
            app.stopPlayback();
            app.IsBusy = true;
            busyCleanup = onCleanup(@()app.finishBusy());
            progress = uiprogressdlg(app.UIFigure, ...
                Title="计算ROI CBV曲线", Message="每帧读取一次，正在计算...", ...
                Value=0, Cancelable="on");
            progressCleanup = onCleanup(@()app.deleteIfValid(progress));
            try
                masks = arrayfun(@(roi)roi.Mask, app.ROIs(pending), ...
                    UniformOutput=false);
                [times, curves] = fus.CBVEngine.calculateROICurves( ...
                    app.Sequence, app.Baseline, masks, parameters, actualFPS, ...
                    @(index, count)app.updateROICurveProgress(progress, index, count));
                if ~app.IsBaselineValid
                    error("fUS:ROIBaselineChanged", ...
                        "计算期间CBV参数已改变，请更新baseline后重试。");
                end
                app.ROICurveTimes = times;
                if isempty(app.ROICurveValues)
                    app.ROICurveValues = nan(numel(times), numel(app.ROIs));
                end
                app.ROICurveValues(:, pending) = curves;
                app.ROICurveValid(pending) = true;
                app.ROICurveParameters = parameters;
                app.ROICurveFPS = actualFPS;
                app.renderROICurves();
                app.scheduleMetadataSave();
                app.StatusLabel.Text = sprintf("已计算 %d 个 ROI；可勾选显示或隐藏", ...
                    numel(pending));
            catch errorInfo
                if ~strcmp(errorInfo.identifier, "fUS:ROICurveCancelled")
                    uialert(app.UIFigure, string(errorInfo.message), "ROI曲线计算失败");
                end
            end
            clear progressCleanup busyCleanup
        end

        function proceed = updateROICurveProgress(~, progress, index, count)
            if mod(index, 25) == 0 || index == count
                progress.Value = index/count;
                progress.Message = sprintf("%d / %d 帧", index, count);
                drawnow limitrate;
            end
            proceed = ~progress.CancelRequested;
        end

        function resetROICurveCache(app)
            app.ROICurveTimes = [];
            app.ROICurveValues = [];
            app.ROICurveValid = false(1, numel(app.ROIs));
            app.ROICurveParameters = struct();
            app.ROICurveFPS = NaN;
            app.renderROICurves();
        end

        function renderROICurves(app)
            if isempty(app.ROICurveAxes) || ~isvalid(app.ROICurveAxes)
                return
            end
            curveAxes = app.ROICurveAxes;
            % cla 只删除可见句柄；时间窗的 patch/text 设置了
            % HandleVisibility="off"，必须显式删除，否则反复重绘会叠加。
            legend(curveAxes, "off");
            delete(allchild(curveAxes));
            app.ROICurveHandles = gobjects(0);
            app.ROICurvePointHandles = gobjects(0);
            app.ROICurvePastHandles = gobjects(0);
            curveAxes.XLimMode = "auto";
            curveAxes.YLimMode = "auto";
            visible = find([app.ROIs.Visible] & app.ROICurveValid);
            curveHandles = gobjects(0);
            curveNames = strings(1, 0);
            curveColors = zeros(0, 3);
            duration = 1;
            if ~isempty(app.Files)
                duration = max(1, numel(app.Files)/app.ActualFPSField.Value);
            end
            if isempty(visible) || isempty(app.ROICurveTimes)
                ylim(curveAxes, [0, 1]);
                title(curveAxes, "添加ROI后点击计算CBV与全部ROI");
            else
                colors = app.roiDisplayColors();
                curveHandles = plot(curveAxes, app.ROICurveTimes, ...
                    app.ROICurveValues(:, visible), LineWidth=1.6);
                for index = 1:numel(visible)
                    curveColors(index, :) = colors(visible(index), :);
                    curveHandles(index).Color = 0.58 + 0.42*curveColors(index, :);
                    curveHandles(index).UserData = visible(index);
                    curveHandles(index).LineWidth = 1.6 ...
                        + 1.6*(visible(index) == app.ROISelectedIndex);
                    curveHandles(index).ButtonDownFcn = @(~, event) ...
                        app.roiCurveClicked(visible(index), event);
                end
                app.ROICurveHandles = curveHandles;
                curveNames = string({app.ROIs(visible).Name});
                if strlength(app.SectionKey) > 0 && app.SectionKey ~= "."
                    sectionName = erase(app.SectionKey, "/SVD");
                    curveNames = sectionName + " · " + curveNames;
                end
                title(curveAxes, "ROI平均CBV时间曲线 · 实验计划时间窗");
            end
            hold(curveAxes, "on");
            external = app.crossSectionCurveSpecs();
            for index = 1:numel(external)
                spec = external(index);
                curve = plot(curveAxes, spec.Times, spec.Values, ...
                    Color=0.58+0.42*spec.Color, LineWidth=1.6);
                curve.UserData = struct(SectionKey=spec.SectionKey, ROIIndex=spec.ROIIndex);
                curve.ButtonDownFcn = @(~, event)app.crossCurveClicked( ...
                    spec.SectionKey, spec.ROIIndex, event);
                curveHandles(end + 1) = curve; %#ok<AGROW>
                curveColors(end + 1, :) = spec.Color; %#ok<AGROW>
                curveNames(end + 1) = spec.Name; %#ok<AGROW>
                duration = max(duration, max(spec.Times));
            end
            if ~isempty(external)
                title(curveAxes, "跨截面ROI时间曲线 · 实验计划共用");
            end
            app.ROICurveHandles = curveHandles;
            xlim(curveAxes, [0, duration]);
            % uiaxes自动布局异步更新，立即读取ylim可能仍为旧的[0,1]。
            % 用真实曲线数值确定范围，保证正负响应及播放亮点都在画面内。
            valueLower = 0;
            valueUpper = 0;
            for index = 1:numel(curveHandles)
                values = curveHandles(index).YData;
                values = values(isfinite(values));
                if ~isempty(values)
                    valueLower = min(valueLower, min(values));
                    valueUpper = max(valueUpper, max(values));
                end
            end
            padding = 0.08*max(1, valueUpper-valueLower);
            yLimits = [valueLower-padding, valueUpper+padding];
            ylim(curveAxes, yLimits);
            for index = 1:numel(curveHandles)
                past = plot(curveAxes, NaN, NaN, Color=curveColors(index, :), ...
                    LineWidth=2.1, HandleVisibility="off", Tag="fUSCurvePast");
                past.ButtonDownFcn = curveHandles(index).ButtonDownFcn;
                point = plot(curveAxes, NaN, NaN, "o", ...
                    MarkerFaceColor=curveColors(index, :), MarkerEdgeColor="white", ...
                    MarkerSize=8, LineWidth=1.4, HandleVisibility="off", ...
                    Tag="fUSCurrentPoint");
                point.ButtonDownFcn = curveHandles(index).ButtonDownFcn;
                past.XLimInclude = "off";
                past.YLimInclude = "off";
                point.XLimInclude = "off";
                point.YLimInclude = "off";
                app.ROICurvePastHandles(end + 1) = past;
                app.ROICurvePointHandles(end + 1) = point;
            end
            plan = app.ExperimentPlan;
            for index = 1:height(plan)
                startTime = max(0, plan.Start_s(index));
                endTime = min(duration, plan.End_s(index));
                if endTime <= startTime
                    continue
                end
                label = string(plan.Label(index));
                isStimulus = any(contains(lower(label), ...
                    ["刺激", "夹捏", "触摸", "stim"]));
                if isStimulus
                    bandColor = [0.93, 0.55, 0.24];
                    textColor = [0.53, 0.28, 0.10];
                else
                    bandColor = [0.30, 0.54, 0.82];
                    textColor = [0.18, 0.32, 0.51];
                end
                band = patch(curveAxes, ...
                    [startTime, endTime, endTime, startTime], ...
                    [yLimits(1), yLimits(1), yLimits(2), yLimits(2)], ...
                    bandColor, FaceAlpha=0.11, EdgeColor="none", ...
                    HandleVisibility="off", HitTest="off");
                % 缩放工具的“显示全部”只按CBV数据定尺度，忽略背景时间窗。
                band.XLimInclude = "off";
                band.YLimInclude = "off";
                uistack(band, "bottom");
                if endTime-startTime >= 0.035*duration
                    phaseLabel = text(curveAxes, (startTime+endTime)/2, ...
                        yLimits(2)-0.025*diff(yLimits), label, ...
                        Rotation=90, FontSize=8, Color=textColor, ...
                        Interpreter="none", VerticalAlignment="top", ...
                        HorizontalAlignment="right", ...
                        HandleVisibility="off", HitTest="off", Clipping="on");
                    phaseLabel.XLimInclude = "off";
                    phaseLabel.YLimInclude = "off";
                end
            end
            hold(curveAxes, "off");
            xlim(curveAxes, [0, duration]);
            ylim(curveAxes, yLimits);
            xlabel(curveAxes, "时间 (s)");
            ylabel(curveAxes, app.currentUnit());
            grid(curveAxes, "on");
            if isempty(curveHandles)
                legend(curveAxes, "off");
            else
                legend(curveAxes, curveHandles, ...
                    curveNames, Location="best", Interpreter="none");
            end
            curveAxes.ButtonDownFcn = @(~, event)app.roiCurveClicked( ...
                app.ROISelectedIndex, event);
            app.updateROICurveCursor();
            app.refreshCrossROIOverview();
        end

        function updateROICurveCursor(app)
            if isempty(app.ROICurveAxes) || ~isvalid(app.ROICurveAxes)
                return
            end
            cursor = findall(app.ROICurveAxes, Tag="fUSCurrentTime");
            if isempty(app.Files)
                delete(cursor);
            elseif isempty(cursor)
                xline(app.ROICurveAxes, app.frameTime(app.CurrentIndex), ...
                    Color=[0.18, 0.22, 0.28], LineStyle="--", ...
                    LineWidth=1.2, Tag="fUSCurrentTime", ...
                    HandleVisibility="off", HitTest="off");
            else
                cursor.Value = app.frameTime(app.CurrentIndex);
            end
            if isempty(app.Files)
                return
            end
            seconds = app.frameTime(app.CurrentIndex);
            for index = 1:min([numel(app.ROICurveHandles), ...
                    numel(app.ROICurvePointHandles), numel(app.ROICurvePastHandles)])
                curve = app.ROICurveHandles(index);
                point = app.ROICurvePointHandles(index);
                past = app.ROICurvePastHandles(index);
                if ~isgraphics(curve) || ~isgraphics(point) || ~isgraphics(past)
                    continue
                end
                times = curve.XData;
                values = curve.YData;
                finite = isfinite(times) & isfinite(values);
                sample = find(finite & times <= seconds, 1, "last");
                if isempty(sample) || seconds > max(times(finite))
                    point.XData = NaN;
                    point.YData = NaN;
                    if seconds > max(times(finite))
                        past.XData = times;
                        past.YData = values;
                    else
                        past.XData = NaN;
                        past.YData = NaN;
                    end
                    continue
                end
                point.XData = times(sample);
                point.YData = values(sample);
                past.XData = times(1:sample);
                past.YData = values(1:sample);
                uistack(point, "top");
            end
        end

        %% CBV baseline、显示和结果保存
        function computeCBVAndAllROIs(app)
            % 只有用户主动计算才联动全项目；载入截面/批处理仍使用局部baseline入口。
            if app.IsBusy || app.IsBatchProcessing || app.IsSelectingROI || isempty(app.Files)
                return
            end
            app.stopPlayback();
            app.computeBaseline();
            if app.IsBaselineValid && app.BaselineEndField.Value > app.BaselineStartField.Value
                app.computeExperimentCurves();
            end
        end

        function computeBaseline(app)
            if isempty(app.Files) || app.IsBusy
                return
            end
            if app.BaselineEndField.Value <= app.BaselineStartField.Value
                uialert(app.UIFigure, "baseline结束时间必须晚于开始时间。", "参数错误");
                return
            end
            app.IsBusy = true;
            app.resetROICurveCache();
            cleanup = onCleanup(@()app.finishBusy());
            app.ComputeBaselineButton.Enable = "off";
            app.StatusLabel.Text = "正在计算共享CBV baseline...";
            drawnow;
            try
                app.Baseline = fus.CBVEngine.computeBaseline( ...
                    app.Sequence, ...
                    [app.BaselineStartField.Value, app.BaselineEndField.Value], ...
                    app.ActualFPSField.Value, app.cbvParameters());
                app.BaselineGray = app.Baseline.Gray;
                app.CBVBackgroundRGB = [];
                app.AnalysisMask = app.Baseline.AnalysisMask;
                indices = app.Baseline.Indices;
                app.IsBaselineValid = true;
                app.SaveCBVButton.Enable = "on";
                app.ExportCBVVideoButton.Enable = "on";
                app.StatusLabel.Text = sprintf("baseline完成：图像 %d-%d", ...
                    indices(1), indices(end));
            catch errorInfo
                app.IsBaselineValid = false;
                app.SaveCBVButton.Enable = "off";
                app.ExportCBVVideoButton.Enable = "off";
                app.StatusLabel.Text = "baseline失败：" + string(errorInfo.message);
                uialert(app.UIFigure, string(errorInfo.message), "计算失败", Icon="error");
            end
            clear cleanup
        end

        function markBaselineDirty(app)
            app.IsBaselineValid = false;
            app.resetROICurveCache();
            app.SaveCBVButton.Enable = "off";
            app.ExportCBVVideoButton.Enable = "off";
            if ~isempty(app.Files)
                app.ComputeBaselineButton.Enable = "on";
                app.StatusLabel.Text = "CBV参数已改变，请重新计算baseline";
            end
        end

        function temporalAverageChanged(app)
            app.resetROICurveCache();
            app.refreshCBV();
        end

        function conversionChanged(app)
            app.updateConversionControls();
            app.markBaselineDirty();
        end

        function updateConversionControls(app)
            mode = string(app.ConversionDropDown.Value);
            app.DynamicRangeField.Enable = matlab.lang.OnOffSwitchState(mode == "dB8bit");
            app.Log10ScaleField.Enable = matlab.lang.OnOffSwitchState(mode == "log10Scaled");
            if mode == "unknown"
                app.UnitLabel.Text = "CBV单位：Δlog灰度（不是CBV%）";
                app.UnitLabel.FontColor = [0.68, 0.26, 0.08];
                app.CBVColorBar.Label.String = "Δlog灰度";
            else
                app.UnitLabel.Text = "CBV单位：%ΔPower Doppler（相对CBV代理量）";
                app.UnitLabel.FontColor = [0.10, 0.42, 0.24];
                app.CBVColorBar.Label.String = "%ΔPD";
            end
            if ~isempty(app.Sequence) && app.DataSourceType == "pdi"
                app.ConversionDropDown.Enable = "off";
            end
        end

        function refreshCBV(app)
            if isempty(app.Files) || ~app.IsBaselineValid ...
                    || app.IsBusy || app.IsSelectingROI
                return
            end
            try
                [map, indices] = app.calculateCBVMap(app.CurrentIndex);
                app.CurrentCBVMap = map;
                app.CurrentAverageIndices = indices;
                app.drawCBVMap(map);
            catch errorInfo
                app.StatusLabel.Text = "CBV刷新失败：" + string(errorInfo.message);
            end
        end

        function drawCBVMap(app, map)
            displayParameters = app.displayParameters();
            backgroundChanged = isempty(app.CBVBackgroundRGB) ...
                || app.CBVBackgroundMode ~= displayParameters.ShowBackground;
            if backgroundChanged
                app.CBVBackgroundRGB = fus.FrameRenderer.baselineBackground( ...
                    app.BaselineGray, displayParameters.ShowBackground);
                app.CBVBackgroundMode = displayParameters.ShowBackground;
            end
            visibleMask = fus.FrameRenderer.visibleMask( ...
                map, app.AnalysisMask, displayParameters);
            alphaData = app.TransparencySlider.Value*double(visibleMask);

            if isempty(app.CBVBackgroundImage) || ~isvalid(app.CBVBackgroundImage)
                wasHeld = ishold(app.CBVAxes);
                hold(app.CBVAxes, "on");
                app.CBVBackgroundImage = image(app.CBVAxes, ...
                    CData=app.CBVBackgroundRGB);
                app.CBVActivityImage = imagesc(app.CBVAxes, map);
                app.CBVActivityImage.AlphaData = alphaData;
                if ~wasHeld
                    hold(app.CBVAxes, "off");
                end
                axis(app.CBVAxes, "image");
                app.CBVAxes.XTick = [];
                app.CBVAxes.YTick = [];
                app.CBVAxes.YDir = "reverse";
                colormap(app.CBVAxes, fus.FrameRenderer.blueWhiteRed(256));
                displayLimit = max(app.HighThresholdField.Value, eps);
                clim(app.CBVAxes, [-displayLimit, displayLimit]);
                app.applyAspect();
            else
                if backgroundChanged
                    app.CBVBackgroundImage.CData = app.CBVBackgroundRGB;
                end
                app.CBVActivityImage.CData = map;
                app.CBVActivityImage.AlphaData = alphaData;
            end
            app.CBVBackgroundImage.Visible = "on";
            app.CBVActivityImage.Visible = "on";
            if ~isempty(app.BrowserImage) && isvalid(app.BrowserImage)
                app.BrowserImage.Visible = "off";
            end
            app.CBVColorBar.Visible = "on";
            % imagesc首次创建时会位于ROI之上。明确图层顺序，ROI只画轮廓。
            uistack(app.CBVActivityImage, "bottom");
            uistack(app.CBVBackgroundImage, "bottom");
            app.drawROIOverlays();
            app.drawDisplayMaskOverlay();
            app.updateTimestampOverlay();
            drawnow limitrate nocallbacks;
        end

        function refreshCBVDisplayOnly(app)
            app.drawDisplayMaskOverlay();
            if isempty(app.CurrentCBVMap) || isempty(app.CBVActivityImage) ...
                    || ~isvalid(app.CBVActivityImage)
                return
            end
            visibleMask = fus.FrameRenderer.visibleMask( ...
                app.CurrentCBVMap, app.AnalysisMask, app.displayParameters());
            app.CBVActivityImage.AlphaData = ...
                app.TransparencySlider.Value*double(visibleMask);
            displayLimit = max(app.HighThresholdField.Value, eps);
            clim(app.CBVAxes, [-displayLimit, displayLimit]);
            app.updateTimestampOverlay();
            drawnow limitrate nocallbacks;
        end

        function transparencyChanging(app, value)
            if isempty(app.CBVActivityImage) || ~isvalid(app.CBVActivityImage)
                return
            end
            currentMask = app.CBVActivityImage.AlphaData > 0;
            app.CBVActivityImage.AlphaData = value*double(currentMask);
            drawnow limitrate nocallbacks;
        end

        function saveCurrentCBVResult(app)
            if ~app.IsBaselineValid || isempty(app.CurrentCBVMap)
                uialert(app.UIFigure, "请先计算baseline并选择时间点。", "没有CBV结果");
                return
            end
            app.ensureResultFolder();
            timeSeconds = app.frameTime(app.CurrentIndex);
            baseName = sprintf("CBV_frame_%06d_time_%09.3fs", ...
                app.CurrentIndex, timeSeconds);
            resultFolder = fullfile(app.ResultFolder, "CBV结果");
            if ~isfolder(resultFolder)
                mkdir(resultFolder);
            end
            result = struct( ...
                SourceFolder=app.DataFolder, ...
                CurrentIndex=app.CurrentIndex, ...
                TimeSeconds=timeSeconds, ...
                AverageImageIndices=app.CurrentAverageIndices, ...
                CBVMap=app.CurrentCBVMap, ...
                BaselineGray=app.BaselineGray, ...
                AnalysisMask=app.AnalysisMask, ...
                ExperimentPlan=app.currentExperimentPlan(), ...
                Configuration=app.collectConfiguration(), ...
                Unit=app.currentUnit());
            save(fullfile(resultFolder, baseName + ".mat"), "result", "-v7.3");
            exportgraphics(app.CBVAxes, fullfile(resultFolder, baseName + ".png"), ...
                Resolution=180);
            app.StatusLabel.Text = "CBV结果已保存：" + baseName;
        end

        %% 工作区配置持久化
        function saveWorkspace(app)
            if isempty(app.Files)
                uialert(app.UIFigure, "请先载入数据。", "没有工作区数据");
                return
            end
            if ~isempty(app.Project)
                app.persistMetadata();
                app.StatusLabel.Text = "实验项目已保存，包含各截面ROI、baseline和曲线结果";
                return
            end
            app.ensureResultFolder();
            app.Bookmarks = app.BookmarkTable.Data;
            workspaceData = struct( ...
                Version="1.2", ...
                SavedAt=string(datetime("now")), ...
                DataFolder=app.DataFolder, ...
                DataSourceType=app.DataSourceType, ...
                ResultFolder=app.ResultFolder, ...
                CurrentIndex=app.CurrentIndex, ...
                Configuration=app.collectConfiguration(), ...
                ExperimentPlan=app.currentExperimentPlan(), ...
                Bookmarks=app.Bookmarks, ...
                ROIs=app.ROIs);
            save(fullfile(app.ResultFolder, "fUS共享工作区.mat"), ...
                "workspaceData", "-v7.3");
            if ~isempty(app.Bookmarks)
                writetable(app.Bookmarks, fullfile(app.ResultFolder, "fUS时间标记.csv"), ...
                    Encoding="UTF-8");
            end
            app.StatusLabel.Text = "共享工作区已保存";
        end

        function loadWorkspace(app)
            [fileName, folder] = uigetfile( ...
                {"*.mat;*.bak", "fUS分析项目或旧工作区"}, "打开实验项目或旧工作区");
            if isequal(fileName, 0)
                return
            end
            loaded = load(fullfile(folder, fileName), "-mat");
            if isfield(loaded, "project")
                [root, folderName] = fileparts(string(folder));
                if folderName ~= "fUS分析项目"
                    root = string(loaded.project.RootFolder);
                end
                if ~isfolder(root)
                    relocated = uigetdir(pwd, "请选择移动后的实验根目录");
                    if isequal(relocated, 0)
                        return
                    end
                    root = string(relocated);
                end
                app.openExperiment(root, ProjectFile=fullfile(folder, fileName));
                return
            end
            if ~isfield(loaded, "workspaceData")
                uialert(app.UIFigure, "所选MAT文件不包含workspaceData。", "格式错误");
                return
            end
            workspaceData = loaded.workspaceData;
            sourceFolder = string(workspaceData.DataFolder);
            if ~isfolder(sourceFolder)
                relocated = uigetdir(pwd, "旧数据路径不可用，请选择此截面的数据目录");
                if isequal(relocated, 0)
                    return
                end
                sourceFolder = string(relocated);
            end
            app.openExperiment(sourceFolder);
            if isempty(app.Project) || isempty(app.Files)
                return
            end
            app.applyConfiguration(workspaceData.Configuration);
            app.ResultFolder = string(workspaceData.ResultFolder);
            app.setResultFolder(app.ResultFolder);
            if isfield(workspaceData, "DataSourceType")
                sourceType = string(workspaceData.DataSourceType);
            elseif isfield(workspaceData.Configuration, "DataSourceType")
                sourceType = string(workspaceData.Configuration.DataSourceType);
            else
                sourceType = app.chooseDataSourceType(string(workspaceData.DataFolder));
            end
            app.loadDataFolder(sourceFolder, sourceType, true);
            if isfield(workspaceData, "ExperimentPlan")
                app.ExperimentPlan = fus.ExperimentPlan.normalize( ...
                    workspaceData.ExperimentPlan);
                app.ExperimentPlanTable.Data = app.ExperimentPlan;
            end
            app.Bookmarks = workspaceData.Bookmarks;
            app.BookmarkTable.Data = app.Bookmarks;
            if isfield(workspaceData, "ROIs") && ~isempty(app.Files)
                imageSize = size(app.readFrame(1));
                candidateROIs = workspaceData.ROIs;
                if all(arrayfun(@(roi)isequal(size(roi.Mask), imageSize(1:2)), ...
                        candidateROIs))
                    if ~isfield(candidateROIs, "Visible")
                        [candidateROIs.Visible] = deal(true);
                    end
                    app.ROIs = candidateROIs;
                    app.resetROICurveCache();
                    app.updateROIStatus();
                end
            end
            app.CurrentIndex = min(numel(app.Files), max(1, workspaceData.CurrentIndex));
            app.TimelineSlider.Value = app.CurrentIndex;
            app.refreshAll();
            app.renderROICurves();
            app.SequenceFingerprint = fus.ExperimentStore.fingerprint(app.DataFolder, app.DataSourceType);
            app.Project.setResultRoot(string(workspaceData.ResultFolder));
            app.persistMetadata();
            app.StatusLabel.Text = "旧工作区已导入实验项目，后续将自动恢复";
        end

        function configuration = collectConfiguration(app)
            configuration = struct( ...
                DataSourceType=app.DataSourceType, ...
                ActualFPS=app.ActualFPSField.Value, ...
                PlaybackFPS=app.PlaybackFPSField.Value, ...
                BrowserColormap=string(app.BrowserColormapDropDown.Value), ...
                ShowTimestamp=app.TimestampCheckBox.Value, ...
                ShowExperimentPhase=app.ShowPhaseCheckBox.Value, ...
                Width=app.WidthField.Value, ...
                Height=app.HeightField.Value, ...
                LockRatio=app.LockRatioCheckBox.Value, ...
                BaselineStart=app.BaselineStartField.Value, ...
                BaselineEnd=app.BaselineEndField.Value, ...
                SpatialAverage=app.SpatialAverageField.Value, ...
                TemporalAverage=app.TemporalAverageField.Value, ...
                ConversionMode=string(app.ConversionDropDown.Value), ...
                DynamicRangeDb=app.DynamicRangeField.Value, ...
                Log10PerGray=app.Log10ScaleField.Value, ...
                MinimumBaselineGray=app.MinimumBaselineField.Value, ...
                LowThreshold=app.LowThresholdField.Value, ...
                HighThreshold=app.HighThresholdField.Value, ...
                Transparency=app.TransparencySlider.Value, ...
                ShowBackground=app.ShowBackgroundCheckBox.Value, ...
                BrainMask=app.BrainMaskCheckBox.Value, ...
                ViewMode=string(app.CurrentViewMode), ...
                ComparisonKeys=app.ComparisonSelectedKeys, ...
                ShowAllSectionCurves=app.ShowAllSectionsCheckBox.Value, ...
                ExportStyle=string(app.ExportStyleDropDown.Value), ...
                ShowROILabels=app.ROILabelsCheckBox.Value, ...
                ReportLayout=app.ReportLayout, ReportCurveFraction=app.ReportCurveFraction, ...
                ReportFrameSize=app.ReportFrameSize, ReportShowROILabels=app.ReportShowROILabels, ...
                SidebarVisible=app.SettingsPanel.Visible == "on");
        end

        function applyConfiguration(app, configuration)
            % 兼容旧工作区，也允许只应用实验共用字段或截面画布字段。
            complete = app.collectConfiguration();
            names = fieldnames(configuration);
            for index = 1:numel(names)
                complete.(names{index}) = configuration.(names{index});
            end
            configuration = complete;
            app.ActualFPSField.Value = configuration.ActualFPS;
            app.PlaybackFPSField.Value = configuration.PlaybackFPS;
            app.BrowserColormapDropDown.Value = configuration.BrowserColormap;
            app.TimestampCheckBox.Value = configuration.ShowTimestamp;
            if isfield(configuration, "ShowExperimentPhase")
                app.ShowPhaseCheckBox.Value = configuration.ShowExperimentPhase;
            end
            app.WidthField.Value = configuration.Width;
            app.HeightField.Value = configuration.Height;
            app.LockRatioCheckBox.Value = configuration.LockRatio;
            app.BaselineStartField.Value = configuration.BaselineStart;
            app.BaselineEndField.Value = configuration.BaselineEnd;
            app.SpatialAverageField.Value = configuration.SpatialAverage;
            app.TemporalAverageField.Value = configuration.TemporalAverage;
            app.ConversionDropDown.Value = configuration.ConversionMode;
            app.DynamicRangeField.Value = configuration.DynamicRangeDb;
            app.Log10ScaleField.Value = configuration.Log10PerGray;
            app.MinimumBaselineField.Value = configuration.MinimumBaselineGray;
            app.LowThresholdField.Value = configuration.LowThreshold;
            app.HighThresholdField.Value = configuration.HighThreshold;
            app.TransparencySlider.Value = configuration.Transparency;
            app.ShowBackgroundCheckBox.Value = configuration.ShowBackground;
            app.BrainMaskCheckBox.Value = configuration.BrainMask;
            if isfield(configuration, "ViewMode")
                app.CurrentViewMode = string(configuration.ViewMode);
                app.ViewModeDropDown.Value = app.CurrentViewMode;
            end
            if isfield(configuration, "ComparisonKeys")
                app.ComparisonSelectedKeys = reshape(string(configuration.ComparisonKeys), 1, []);
            end
            if isfield(configuration, "ShowAllSectionCurves")
                app.ShowAllSectionsCheckBox.Value = configuration.ShowAllSectionCurves;
            end
            if isfield(configuration, "ExportStyle")
                app.ExportStyleDropDown.Value = string(configuration.ExportStyle);
            end
            app.ROILabelsCheckBox.Value = configuration.ShowROILabels;
            app.ReportLayout = string(configuration.ReportLayout);
            app.ReportCurveFraction = configuration.ReportCurveFraction;
            app.ReportFrameSize = configuration.ReportFrameSize;
            app.ReportShowROILabels = configuration.ReportShowROILabels;
            if isfield(configuration, "SidebarVisible")
                app.SettingsPanel.Visible = matlab.lang.OnOffSwitchState(configuration.SidebarVisible);
                if configuration.SidebarVisible
                    app.BodyGrid.ColumnWidth = {"1x", 320};
                else
                    app.BodyGrid.ColumnWidth = {"1x", 0};
                end
            end
            app.updateConversionControls();
        end

        %% 时间点标记与视频导出
        function ensureResultFolder(app)
            if strlength(app.ResultFolder) == 0
                app.setResultFolder(fullfile(fileparts(app.DataFolder), "fUS工作区结果"));
            elseif ~isfolder(app.ResultFolder)
                mkdir(app.ResultFolder);
            end
        end

        function addBookmark(app)
            if isempty(app.Files)
                return
            end
            [~, name, extension] = fileparts(app.Files(app.CurrentIndex));
            seconds = app.frameTime(app.CurrentIndex);
            row = table(app.CurrentIndex, ...
                seconds, string(name + extension), app.phaseForTime(seconds), ...
                VariableNames=app.Bookmarks.Properties.VariableNames);
            app.Bookmarks = [app.Bookmarks; row];
            app.BookmarkTable.Data = app.Bookmarks;
        end

        function deleteBookmark(app)
            selection = app.BookmarkTable.Selection;
            if isempty(selection)
                return
            end
            app.Bookmarks = app.BookmarkTable.Data;
            app.Bookmarks(unique(selection(:, 1)), :) = [];
            app.BookmarkTable.Data = app.Bookmarks;
        end

        function saveBookmarks(app)
            app.ensureResultFolder();
            app.Bookmarks = app.BookmarkTable.Data;
            writetable(app.Bookmarks, fullfile(app.ResultFolder, "fUS时间标记.csv"), ...
                Encoding="UTF-8");
            app.StatusLabel.Text = "时间标记已保存到共享结果文件夹";
        end

        function exportVideo(app)
            if isempty(app.Files) || app.IsBusy
                return
            end
            if app.CurrentViewMode == "cbv" && ~app.IsBaselineValid
                uialert(app.UIFigure, "请先计算baseline再导出CBV视频。", "CBV尚未就绪");
                return
            end
            app.stopPlayback();
            try
                if ~isempty(app.ROIs) && ~all(app.ROICurveValid) && app.IsBaselineValid
                    app.showROICurves();
                end
                specification = struct(FrameCount=numel(app.Files), ...
                    ActualFPS=app.ActualFPSField.Value, InitialIndex=app.CurrentIndex, ...
                    Modal=true, Settings=struct(Style=string(app.ExportStyleDropDown.Value), ...
                        Layout=app.ReportLayout, CurveFraction=app.ReportCurveFraction, ...
                        FrameSize=app.ReportFrameSize, ShowROILabels=app.ReportShowROILabels), ...
                    ReportConfiguration=fUSWorkspaceComparisonWorkflow.reportConfiguration(app), ...
                    ImageProvider=@(index)fUSWorkspaceComparisonWorkflow.exportImages(app, index), ...
                    PureImageProvider=@(index)app.renderImageVideoFrame(index));
                app.IsBusy = true;
                busyCleanup = onCleanup(@()app.finishBusy());
                preview = fUSWorkspaceExportPreview(specification);
                previewCleanup = onCleanup(@()delete(preview));
                settings = preview.run();
                clear previewCleanup busyCleanup
                if isempty(settings)
                    app.StatusLabel.Text = "已取消视频导出；未生成文件";
                    return
                end
                app.ExportStyleDropDown.Value = settings.Style;
                app.ReportLayout = settings.Layout;
                app.ReportCurveFraction = settings.CurveFraction;
                app.ReportFrameSize = settings.FrameSize;
                app.ReportShowROILabels = settings.ShowROILabels;
                app.scheduleMetadataSave();
            catch errorInfo
                app.StatusLabel.Text = "导出预览失败：" + string(errorInfo.message);
                uialert(app.UIFigure, string(errorInfo.message), "预览失败", Icon="error");
                return
            end
            app.ensureResultFolder();
            if app.CurrentViewMode == "cbv"
                defaultName = "fUS_CBV_overlay.mp4";
            else
                defaultName = "fUS_original.mp4";
            end
            [fileName, folder] = uiputfile("*.mp4", "导出fUS视频", ...
                fullfile(app.ResultFolder, defaultName));
            if isequal(fileName, 0)
                return
            end
            [~, baseName, extension] = fileparts(fileName);
            if ~strcmpi(extension, ".mp4")
                fileName = char(string(baseName) + ".mp4");
            end

            try
                outputPath = fullfile(folder, fileName);
                app.exportVideoToPath(outputPath, ShowProgress=true);
            catch errorInfo
                app.StatusLabel.Text = "视频导出失败：" + string(errorInfo.message);
                uialert(app.UIFigure, string(errorInfo.message), "导出失败", Icon="error");
            end
        end

        function exportCBVVideo(app)
            if isempty(app.Files) || app.IsBusy
                return
            end
            if ~app.IsBaselineValid
                uialert(app.UIFigure, ...
                    "请先按当前参数计算baseline，再导出CBV视频。", ...
                    "CBV尚未就绪");
                return
            end
            % The CBV-tab button must always export the CBV canvas.  This also
            % protects the callback if the tab state changes programmatically.
            app.CurrentViewMode = "cbv";
            app.refreshCBV();
            app.exportVideo();
        end

        function videoExport = exportVideoToPath(app, outputPath, options)
            arguments
                app
                outputPath (1, 1) string
                options.ShowProgress (1, 1) logical = true
                options.ProgressFcn = []
                options.Style (1, 1) string = ""
            end

            app.stopPlayback();
            style = options.Style;
            if strlength(style) == 0
                style = string(app.ExportStyleDropDown.Value);
            end
            if style == "presentation" && ~isempty(app.ROIs) ...
                    && ~all(app.ROICurveValid) && app.IsBaselineValid
                app.showROICurves();
            end
            renderer = [];
            if style == "presentation"
                app.renderROICurves();
                reportConfiguration = fUSWorkspaceComparisonWorkflow.reportConfiguration(app);
                renderer = fus.ReportRenderer(reportConfiguration);
            end
            rendererCleanup = onCleanup(@()app.deleteIfValid(renderer));
            app.IsBusy = true;
            cleanup = onCleanup(@()app.finishBusy());
            progress = [];
            if options.ShowProgress
                progress = uiprogressdlg(app.UIFigure, Title="正在导出视频", ...
                    Message="准备中...", Cancelable="on", Value=0);
                progressCleanup = onCleanup(@()app.deleteIfValid(progress));
            end

            writer = VideoWriter(outputPath, "MPEG-4");
            writer.FrameRate = app.PlaybackFPSField.Value;
            writer.Quality = 95;
            open(writer);
            writerCleanup = onCleanup(@()app.closeVideoWriter(writer));

            videoGeometry = fus.FrameRenderer.videoGeometry( ...
                app.WidthField.Value/app.HeightField.Value);
            if style == "presentation"
                videoGeometry = struct(ContentHeight=renderer.FrameSize(1), ...
                    ContentWidth=renderer.FrameSize(2), CanvasHeight=renderer.FrameSize(1), ...
                    CanvasWidth=renderer.FrameSize(2), Alignment=16);
            end
            imageCount = numel(app.Files);
            for index = 1:imageCount
                if ~isempty(options.ProgressFcn) && ~options.ProgressFcn(index, imageCount)
                    error("fUS:BatchCancelled", "批量视频导出已取消。");
                end
                if options.ShowProgress && progress.CancelRequested
                    clear writerCleanup
                    app.StatusLabel.Text = "视频导出已取消";
                    videoExport = struct([]);
                    clear progressCleanup cleanup
                    return
                end
                if style == "presentation"
                    images = fUSWorkspaceComparisonWorkflow.exportImages(app, index);
                    frame = renderer.render(images, app.frameTime(index));
                else
                    frame = app.renderImageVideoFrame(index);
                end
                writeVideo(writer, im2uint8(frame));
                if mod(index, 5) == 0 || index == imageCount
                    if options.ShowProgress
                        progress.Value = index/imageCount;
                        progress.Message = sprintf("第 %d / %d 帧", ...
                            index, imageCount);
                    end
                    drawnow limitrate;
                end
            end
            clear writerCleanup

            fileInfo = dir(outputPath);
            if isempty(fileInfo) || fileInfo.bytes == 0
                error("fUSWorkspace:EmptyVideo", ...
                    "编码器没有生成有效的MP4文件。");
            end
            [folder, baseName] = fileparts(outputPath);
            videoExport = struct( ...
                SourceFolder=app.DataFolder, ...
                OutputPath=string(outputPath), ...
                ExportedAt=string(datetime("now")), ...
                Mode=app.CurrentViewMode, ...
                Style=style, ...
                Unit=app.currentUnit(), ...
                FrameCount=imageCount, ...
                VideoFrameRate=app.PlaybackFPSField.Value, ...
                VideoCanvasSize=[videoGeometry.CanvasHeight, ...
                    videoGeometry.CanvasWidth], ...
                VideoContentSize=[videoGeometry.ContentHeight, ...
                    videoGeometry.ContentWidth], ...
                CodecAlignment=videoGeometry.Alignment, ...
                Configuration=app.collectConfiguration(), ...
                UserDisplayMask=app.UserDisplayMask, ...
                UserDisplayMaskVertices=app.UserDisplayMaskVertices, ...
                ExperimentPlan=app.currentExperimentPlan());
            if style == "presentation"
                videoExport.ReportConfiguration = reportConfiguration;
            end
            save(fullfile(folder, string(baseName) + "_settings.mat"), ...
                "videoExport", "-v7.3");
            app.StatusLabel.Text = "视频已导出：" + outputPath;
            clear rendererCleanup progressCleanup cleanup
        end

        %% 时间轴、播放与画布比例
        function frame = renderImageVideoFrame(app, index)
            % 纯图像预览与实际导出共用同一条路径，尺寸和时间标注完全一致。
            geometry = fus.FrameRenderer.videoGeometry(app.WidthField.Value/app.HeightField.Value);
            frame = fus.FrameRenderer.fitToVideoCanvas(app.renderFrameForExport(index), geometry);
            if app.TimestampCheckBox.Value
                frame = app.drawTimestamp(frame, app.timeLabel(index));
            end
        end

        function sliderMoving(app, value)
            if isempty(app.Files) || app.IsBusy
                return
            end
            app.CurrentIndex = min(numel(app.Files), max(1, round(value)));
            app.TimelineSlider.Value = app.CurrentIndex;
            app.refreshAll();
        end

        function updateFrameLabel(app)
            if isempty(app.Files)
                app.FrameLabel.Text = "0 / 0";
                app.PhaseLabel.Text = "共享画面：尚未载入数据";
                return
            end
            seconds = app.frameTime(app.CurrentIndex);
            app.FrameLabel.Text = sprintf("%d / %d · %.2f s", ...
                app.CurrentIndex, numel(app.Files), seconds);
            phase = app.phaseForTime(seconds);
            if strlength(phase) == 0
                phase = "计划外";
            end
            app.PhaseLabel.Text = sprintf("共享画面：%.2f s · %s", seconds, phase);
            [~, name, extension] = fileparts(app.Files(app.CurrentIndex));
            app.StatusLabel.Text = sprintf("%s%s · %s", ...
                name, extension, app.currentUnit());
        end

        function currentUnit = currentUnit(app)
            currentUnit = fus.CBVEngine.unitLabel(app.cbvParameters());
        end

        function togglePlayback(app)
            if strcmp(app.PlaybackTimer.Running, "on")
                app.stopPlayback();
            else
                if isempty(app.Files)
                    return
                end
                app.IsEditingDisplayMask = false;
                app.drawDisplayMaskOverlay();
                if app.CurrentIndex >= numel(app.Files)
                    app.CurrentIndex = 1;
                    app.TimelineSlider.Value = 1;
                end
                app.PlaybackStartIndex = app.CurrentIndex;
                app.PlaybackClock = tic;
                app.PlaybackTimer.Period = min(0.1, ...
                    max(0.02, 1.0/app.PlaybackFPSField.Value));
                start(app.PlaybackTimer);
                app.PlayButton.Text = "暂停";
            end
        end

        function playbackTick(app)
            if isempty(app.Files) || isempty(app.PlaybackClock)
                app.stopPlayback();
                return
            end
            if app.IsBusy || app.IsSelectingROI
                return
            end
            targetIndex = min(numel(app.Files), app.PlaybackStartIndex + ...
                floor(toc(app.PlaybackClock)*app.PlaybackFPSField.Value));
            if targetIndex <= app.CurrentIndex
                return
            end
            app.CurrentIndex = targetIndex;
            app.TimelineSlider.Value = app.CurrentIndex;
            app.refreshAll();
            if app.CurrentIndex >= numel(app.Files)
                app.stopPlayback();
            end
        end

        function stopPlayback(app)
            if ~isempty(app.PlaybackTimer) && isvalid(app.PlaybackTimer) ...
                    && strcmp(app.PlaybackTimer.Running, "on")
                stop(app.PlaybackTimer);
            end
            if ~isempty(app.PlayButton) && isvalid(app.PlayButton)
                app.PlayButton.Text = "播放";
            end
            app.PlaybackClock = [];
        end

        function actualFPSChanged(app)
            app.markBaselineDirty();
            app.refreshSharedView();
            app.updateFrameLabel();
        end

        function playbackFPSChanged(app)
            if ~isempty(app.PlaybackTimer) && isvalid(app.PlaybackTimer) ...
                    && strcmp(app.PlaybackTimer.Running, "on")
                stop(app.PlaybackTimer);
                app.PlaybackStartIndex = app.CurrentIndex;
                app.PlaybackClock = tic;
                app.PlaybackTimer.Period = min(0.1, ...
                    max(0.02, 1.0/app.PlaybackFPSField.Value));
                start(app.PlaybackTimer);
            end
        end

        function widthChanged(app)
            if app.LockRatioCheckBox.Value
                app.HeightField.Value = app.WidthField.Value/app.LockedRatio;
            end
            app.applyAspect();
        end

        function heightChanged(app)
            if app.LockRatioCheckBox.Value
                app.WidthField.Value = app.HeightField.Value*app.LockedRatio;
            end
            app.applyAspect();
        end

        function lockRatioChanged(app)
            if app.LockRatioCheckBox.Value
                app.LockedRatio = app.WidthField.Value/app.HeightField.Value;
            end
        end

        function applyAspect(app)
            width = app.WidthField.Value;
            height = app.HeightField.Value;
            imageHandles = {app.BrowserImage, app.CBVBackgroundImage, app.CBVActivityImage};
            for k = 1:numel(imageHandles)
                imageHandle = imageHandles{k};
                if ~isempty(imageHandle) && isvalid(imageHandle)
                    imageHandle.XData = [0, width];
                    imageHandle.YData = [0, height];
                end
            end
            app.BrowserAxes.XLim = [0, width];
            app.BrowserAxes.YLim = [0, height];
            app.BrowserAxes.YDir = "reverse";
            pbaspect(app.BrowserAxes, [width, height, 1]);
            app.updateTimestampOverlay();
            app.drawROIOverlays();
        end

        %% 图像读取、缓存与 CBV 数值计算
        function frame = readFrame(app, index)
            frame = app.Sequence.readFrame(index);
        end

        function clearCache(app)
            if ~isempty(app.Sequence)
                app.Sequence.clearCache();
            end
        end

        function shown = colorizeFrame(~, frame, palette)
            shown = fus.FrameRenderer.colorizeOriginal(frame, palette);
        end

        function [map, indices] = calculateCBVMap(app, centerIndex)
            [map, indices] = fus.CBVEngine.calculateMap( ...
                app.Sequence, app.Baseline, centerIndex, app.cbvParameters());
        end

        function frame = renderFrameForExport(app, index)
            if app.CurrentViewMode == "browser"
                frame = app.colorizeFrame(app.readFrame(index), ...
                    string(app.BrowserColormapDropDown.Value));
                return
            end

            [map, ~] = app.calculateCBVMap(index);
            frame = fus.FrameRenderer.renderCBV( ...
                map, app.BaselineGray, app.AnalysisMask, app.displayParameters());
        end

        function label = timeLabel(app, index)
            seconds = app.frameTime(index);
            hours = floor(seconds/3600);
            minutes = floor(mod(seconds, 3600)/60);
            secondsPart = mod(seconds, 60);
            label = sprintf("%02d:%02d:%06.3f", hours, minutes, secondsPart);
            if app.ShowPhaseCheckBox.Value
                phase = app.phaseForTime(seconds);
                if strlength(phase) > 0
                    label = label + " | " + phase;
                end
            end
        end

        function seconds = frameTime(app, index)
            % Each SVD image is timestamped at the end of its acquisition block.
            % For 500 raw frames at 1000 Hz, image 1 is therefore 0.5 s.
            seconds = double(index)/app.ActualFPSField.Value;
        end

        function frame = drawTimestamp(~, frame, label)
            frame = fus.FrameRenderer.drawTimestamp(frame, label);
        end

        function parameters = cbvParameters(app)
            % 这是界面与算法之间唯一的参数转换点。
            spatialPixels = round(app.SpatialAverageField.Value);
            if mod(spatialPixels, 2) == 0
                spatialPixels = spatialPixels + 1;
                app.SpatialAverageField.Value = spatialPixels;
            end
            parameters = struct( ...
                SpatialAveragePixels=spatialPixels, ...
                TemporalAverageFrames=round(app.TemporalAverageField.Value), ...
                ConversionMode=string(app.ConversionDropDown.Value), ...
                DynamicRangeDb=app.DynamicRangeField.Value, ...
                Log10PerGray=app.Log10ScaleField.Value, ...
                MinimumBaselineGray=app.MinimumBaselineField.Value);
        end

        function parameters = displayParameters(app)
            % 显示参数不参与 CBV 数值计算，只决定可视化和视频外观。
            parameters = struct( ...
                LowThreshold=app.LowThresholdField.Value, ...
                HighThreshold=app.HighThresholdField.Value, ...
                Transparency=app.TransparencySlider.Value, ...
                ShowBackground=app.ShowBackgroundCheckBox.Value, ...
                BrainMask=app.BrainMaskCheckBox.Value, ...
                ApplyUserMask=true, UserMask=app.UserDisplayMask, ...
                ValidSignalMask=isfinite(app.BaselineGray) & app.BaselineGray > 0);
        end

        function ensureCorePath(~)
            appFolder = fileparts(mfilename("fullpath"));
            coreFolder = fullfile(fileparts(appFolder), "core");
            if isfolder(coreFolder)
                addpath(coreFolder);
            end
        end

        function iconFile = appIconPath(~)
            appFolder = fileparts(mfilename("fullpath"));
            iconFile = fullfile(fileparts(appFolder), "assets", "icons", ...
                "fUSWorkspace_AppIcon_256.png");
        end

        %% 清理与关闭
        function finishBusy(app)
            app.IsBusy = false;
            app.drawROIOverlays();
            if ~isempty(app.Files)
                app.ComputeBaselineButton.Enable = "on";
            end
            if app.IsBaselineValid
                app.refreshAll();
            end
        end

        function closeVideoWriter(~, writer)
            try
                close(writer);
            catch
                % Preserve the original export error.
            end
        end

        function deleteIfValid(~, object)
            try
                if ~isempty(object) && isvalid(object)
                    delete(object);
                end
            catch
                % The dialog may already have been closed.
            end
        end

        function closeApp(app)
            app.stopPlayback();
            if app.IsBusy || app.IsBatchProcessing
                uialert(app.UIFigure, "请先取消或等待当前处理结束，再关闭项目。", "正在处理");
                return
            end
            try
                app.persistMetadata();
            catch errorInfo
                uialert(app.UIFigure, "关闭前保存未成功：" + string(errorInfo.message), ...
                    "请先检查保存目录");
                return
            end
            delete(app);
        end
    end

    % ======================== 无状态工具方法 ========================
    methods (Static, Access = {?fUSWorkspaceProjectWorkflow, ?fUSWorkspaceComparisonWorkflow})
        function value = fieldOr(source, name, fallback)
            value = fallback;
            if isfield(source, name)
                value = source.(name);
            end
        end
        function compact = compactPath(pathValue)
            pathValue = string(pathValue);
            if strlength(pathValue) > 50
                compact = "..." + extractAfter(pathValue, strlength(pathValue) - 46);
            else
                compact = pathValue;
            end
        end

    end
end
