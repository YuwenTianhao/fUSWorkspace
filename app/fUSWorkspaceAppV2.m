classdef fUSWorkspaceAppV2 < handle
    % fUSWorkspaceAppV2 可运行的 fUS 工作区参考实现。
    %
    % 架构：
    %   1. 本类保存运行状态并协调回调和工作流；
    %   2. fUSWorkspaceLayout 只创建纯 MATLAB uifigure 界面；
    %   3. fus.ImageSequence 负责图像序列和缓存；
    %   4. fus.CBVEngine 负责全部 baseline 和 CBV 数值计算；
    %   5. fus.ExperimentPlan 与 fus.FrameRenderer 分别负责阶段和画面。
    %
    % 新算法应进入 core/+fus，不要写进本控制器。参见：
    % docs/如何添加新算法.md

    % ======================== 界面组件 ========================
    properties (Access = private)
        Layout
        UIFigure
        MainGrid
        TabGroup
        BrowserTab
        CBVTab
        ExperimentTab
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
    properties (Access = private)
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
        ROISelectedIndex double = 0
        ROICurveTimes double = []
        ROICurveValues double = []
        ROICurveValid logical = false(1, 0)
        ROICurveParameters struct = struct()
        ROICurveFPS double = NaN
    end

    % ======================== 生命周期与公开接口 ========================
    methods
        function app = fUSWorkspaceAppV2(startFolder)
            app.ensureCorePath();
            app.Bookmarks = table([], [], strings(0, 1), strings(0, 1), ...
                VariableNames=["Frame", "Time_s", "File", "Note"]);
            app.ExperimentPlan = app.defaultExperimentPlan();
            app.buildUI();
            app.PlaybackTimer = timer( ...
                ExecutionMode="fixedRate", BusyMode="drop", Period=0.1, ...
                TimerFcn=@(~, ~)app.playbackTick());
            app.UIFigure.CloseRequestFcn = @(~, ~)app.closeApp();
            app.updateConversionControls();
            if nargin > 0 && strlength(string(startFolder)) > 0
                app.loadDataFolder(string(startFolder));
            end
        end

        function delete(app)
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
            videoExport = app.exportVideoToPath(outputPath, ShowProgress=false);
        end
    end

    methods (Access = private)
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
            callbacks.computeBaseline = @()app.computeBaseline();
            callbacks.saveCurrentCBVResult = @()app.saveCurrentCBVResult();
            callbacks.exportCBVVideo = @()app.exportCBVVideo();
            callbacks.addPolygonROI = @()app.addPolygonROI();
            callbacks.removeSelectedROI = @()app.removeSelectedROI();
            callbacks.roiVisibilityChanged = @(event)app.roiVisibilityChanged(event);
            callbacks.roiSelected = @(event)app.roiSelected(event);
            callbacks.showROICurves = @()app.showROICurves();
            callbacks.experimentPlanChanged = @()app.experimentPlanChanged();
            callbacks.resetExperimentPlan = @()app.resetExperimentPlan();
            callbacks.loadExperimentPlan = @()app.loadExperimentPlan();
            callbacks.saveExperimentPlan = @()app.saveExperimentPlan();
            callbacks.togglePlayback = @()app.togglePlayback();
            callbacks.sliderMoving = @(value)app.sliderMoving(value);
            callbacks.actualFPSChanged = @()app.actualFPSChanged();
            callbacks.playbackFPSChanged = @()app.playbackFPSChanged();

            app.Layout = fUSWorkspaceLayout( ...
                callbacks, app.Bookmarks, app.ExperimentPlan, app.appIconPath());
            components = app.Layout.components();
            names = string(fieldnames(components));
            for index = 1:numel(names)
                app.(names(index)) = components.(names(index));
            end
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
            app.StatusLabel.Text = "已恢复本次9分钟胡须实验计划";
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
            sourceType = app.chooseDataSourceType(string(folder));
            if strlength(sourceType) > 0
                app.loadDataFolder(string(folder), sourceType);
            end
        end

        function loadDataFolder(app, folder, sourceType, preserveImageSettings)
            if nargin < 3 || strlength(string(sourceType)) == 0
                sourceType = app.chooseDataSourceType(folder);
            end
            if nargin < 4
                preserveImageSettings = false;
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
            catch errorInfo
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

            firstFrame = app.readFrame(1);
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
            app.StatusLabel.Text = "数据已载入；正在计算CBV baseline...";
            app.computeBaseline();
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
            app.setResultFolder(string(folder));
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
        end

        function refreshSharedView(app)
            if app.CurrentViewMode == "cbv"
                app.refreshCBV();
            else
                app.refreshBrowser();
            end
        end

        function viewTabChanged(app, selectedTab)
            if selectedTab == app.BrowserTab
                app.CurrentViewMode = "browser";
                app.ImagePanel.Title = "共享画面 · 原始SVD";
            elseif selectedTab == app.CBVTab
                app.CurrentViewMode = "cbv";
                app.ImagePanel.Title = "共享画面 · 相对CBV叠加";
            end
            app.refreshSharedView();
            app.updateFrameLabel();
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
            app.TabGroup.SelectedTab = app.BrowserTab;
            app.viewTabChanged(app.BrowserTab);
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
                    Color=colors(roiIndex, :), LineWidth=2);
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
                app.updateROIStatus();
                app.drawROIOverlays();
                app.renderROICurves();
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
                app.ROISelectedIndex = 0;
            else
                app.ROISelectedIndex = event.Indices(1, 1);
            end
        end

        function roiVisibilityChanged(app, event)
            if isempty(event.Indices) || event.Indices(1, 2) ~= 1
                return
            end
            index = event.Indices(1, 1);
            if index < 1 || index > numel(app.ROIs)
                return
            end
            app.ROIs(index).Visible = logical(event.NewData);
            app.drawROIOverlays();
            app.renderROICurves();
        end

        function drawROIOverlays(app)
            if isempty(app.ROIs) || isempty(app.Files) ...
                    || isempty(app.BrowserAxes) || ~isvalid(app.BrowserAxes)
                for index = 1:numel(app.ROIOverlayHandles)
                    app.deleteIfValid(app.ROIOverlayHandles{index});
                end
                app.ROIOverlayHandles = {};
                return
            end
            canReuse = numel(app.ROIOverlayHandles) == 2*numel(app.ROIs);
            if canReuse
                canReuse = all(cellfun(@(handle)isvalid(handle), ...
                    app.ROIOverlayHandles));
            end
            if ~canReuse
                for index = 1:numel(app.ROIOverlayHandles)
                    app.deleteIfValid(app.ROIOverlayHandles{index});
                end
                app.ROIOverlayHandles = cell(1, 2*numel(app.ROIs));
            end
            colors = lines(max(7, numel(app.ROIs)));
            wasHeld = ishold(app.BrowserAxes);
            hold(app.BrowserAxes, "on");
            for index = 1:numel(app.ROIs)
                vertices = app.ROIs(index).NormalizedPosition .* ...
                    [app.WidthField.Value, app.HeightField.Value];
                points = [vertices; vertices(1, :)];
                if canReuse
                    outline = app.ROIOverlayHandles{2*index - 1};
                    label = app.ROIOverlayHandles{2*index};
                    outline.XData = points(:, 1);
                    outline.YData = points(:, 2);
                    label.Position = [points(1, :), 0];
                else
                    outline = plot(app.BrowserAxes, points(:, 1), points(:, 2), ...
                        Color=colors(index, :), LineWidth=2, HitTest="off");
                    label = text(app.BrowserAxes, points(1, 1), points(1, 2), ...
                        app.ROIs(index).Name, Color=colors(index, :), ...
                        FontWeight="bold", BackgroundColor="k", ...
                        Interpreter="none", HitTest="off");
                    app.ROIOverlayHandles(2*index - 1:2*index) = {outline, label};
                end
                visibility = matlab.lang.OnOffSwitchState(app.ROIs(index).Visible);
                outline.Visible = visibility;
                label.Visible = visibility;
            end
            if ~wasHeld
                hold(app.BrowserAxes, "off");
            end
            for index = 1:numel(app.ROIOverlayHandles)
                uistack(app.ROIOverlayHandles{index}, "top");
            end
            if ~isempty(app.TimestampText) && isvalid(app.TimestampText)
                uistack(app.TimestampText, "top");
            end
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
            curveAxes.XLimMode = "auto";
            curveAxes.YLimMode = "auto";
            visible = find([app.ROIs.Visible] & app.ROICurveValid);
            curveHandles = gobjects(0);
            duration = 1;
            if ~isempty(app.Files)
                duration = max(1, numel(app.Files)/app.ActualFPSField.Value);
            end
            if isempty(visible) || isempty(app.ROICurveTimes)
                ylim(curveAxes, [0, 1]);
                title(curveAxes, "选择ROI后点击计算/更新曲线");
            else
                colors = lines(max(7, numel(app.ROIs)));
                curveHandles = plot(curveAxes, app.ROICurveTimes, ...
                    app.ROICurveValues(:, visible), LineWidth=1.6);
                for index = 1:numel(visible)
                    curveHandles(index).Color = colors(visible(index), :);
                end
                title(curveAxes, "ROI平均CBV时间曲线 · 实验计划时间窗");
            end
            xlim(curveAxes, [0, duration]);
            yLimits = ylim(curveAxes);
            hold(curveAxes, "on");
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
                    string({app.ROIs(visible).Name}), Location="best");
            end
        end

        %% CBV baseline、显示和结果保存
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
                colormap(app.CBVAxes, fus.FrameRenderer.blueWhiteOrange(256));
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
            app.updateTimestampOverlay();
            drawnow limitrate nocallbacks;
        end

        function refreshCBVDisplayOnly(app)
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
            [fileName, folder] = uigetfile("*.mat", "载入fUS共享工作区");
            if isequal(fileName, 0)
                return
            end
            loaded = load(fullfile(folder, fileName), "workspaceData");
            if ~isfield(loaded, "workspaceData")
                uialert(app.UIFigure, "所选MAT文件不包含workspaceData。", "格式错误");
                return
            end
            workspaceData = loaded.workspaceData;
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
            app.loadDataFolder(string(workspaceData.DataFolder), sourceType, true);
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
            app.StatusLabel.Text = "共享工作区已载入";
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
                BrainMask=app.BrainMaskCheckBox.Value);
        end

        function applyConfiguration(app, configuration)
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
            end

            app.stopPlayback();
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
            imageCount = numel(app.Files);
            for index = 1:imageCount
                if options.ShowProgress && progress.CancelRequested
                    clear writerCleanup
                    app.StatusLabel.Text = "视频导出已取消";
                    videoExport = struct([]);
                    clear progressCleanup cleanup
                    return
                end
                frame = app.renderFrameForExport(index);
                frame = fus.FrameRenderer.fitToVideoCanvas(frame, videoGeometry);
                if app.TimestampCheckBox.Value
                    frame = app.drawTimestamp(frame, app.timeLabel(index));
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
                Unit=app.currentUnit(), ...
                FrameCount=imageCount, ...
                VideoFrameRate=app.PlaybackFPSField.Value, ...
                VideoCanvasSize=[videoGeometry.CanvasHeight, ...
                    videoGeometry.CanvasWidth], ...
                VideoContentSize=[videoGeometry.ContentHeight, ...
                    videoGeometry.ContentWidth], ...
                CodecAlignment=videoGeometry.Alignment, ...
                Configuration=app.collectConfiguration(), ...
                ExperimentPlan=app.currentExperimentPlan());
            save(fullfile(folder, string(baseName) + "_settings.mat"), ...
                "videoExport", "-v7.3");
            app.StatusLabel.Text = "视频已导出：" + outputPath;
            clear progressCleanup cleanup
        end

        %% 时间轴、播放与画布比例
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
                BrainMask=app.BrainMaskCheckBox.Value);
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
            delete(app);
        end
    end

    % ======================== 无状态工具方法 ========================
    methods (Static, Access = private)
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
