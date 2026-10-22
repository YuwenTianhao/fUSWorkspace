classdef fUSWorkspaceProjectWorkflow
    %FUSWORKSPACEPROJECTWORKFLOW 实验项目的打开、切换、恢复与批量处理。
    %
    % 本类组织多截面工作流；fUSWorkspaceProject 管理共用设置和截面状态，
    % fus.ExperimentStore 负责文件存储。这里不实现 CBV 数值算法或界面布局。
    % app 显式传入，流程使用同一控制器状态，不创建第二套数据或界面。

    methods (Static)
        function openExperiment(app, root, options)
            % 可从脚本或界面打开整个实验；自动恢复上次截面和共用参数。
            arguments
                app
                root (1, 1) string
                options.ProjectFile (1, 1) string = ""
                options.PreferredDataFolder (1, 1) string = ""
            end
            if app.IsBusy || app.IsBatchProcessing
                return
            end
            app.persistMetadata();
            previous = app.captureLiveSnapshot();
            try
                project = fUSWorkspaceProject(string(root), ...
                    app.collectConfiguration(), app.currentExperimentPlan(), ...
                    SourceFile=options.ProjectFile);
                app.Project = project;
                app.SectionKey = "";
                app.ComparisonSelectedKeys = strings(0, 1);
                app.ComparisonCache = app.ComparisonCache([], :);
                sections = project.Data.Sections;
                app.SectionDropDown.Items = string({sections.Name});
                app.SectionDropDown.ItemsData = string({sections.Key});
                app.SectionDropDown.Enable = "on";
                key = string(project.Data.LastSectionKey);
                if ~any(string({sections.Key}) == key)
                    key = string(sections(1).Key);
                end
                if strlength(options.PreferredDataFolder) > 0
                    paths = string({sections.DataFolder});
                    preferred = find(paths == options.PreferredDataFolder ...
                        | paths == fullfile(options.PreferredDataFolder, "SVD"), 1);
                    if ~isempty(preferred)
                        key = string(sections(preferred).Key);
                    end
                end
                if ~app.sectionChanged(key)
                    app.restoreLiveSnapshot(previous);
                    return
                end
                if strlength(app.SectionKey) > 0
                    setpref("fUSWorkspace", "LastExperimentRoot", char(project.RootFolder));
                end
            catch errorInfo
                app.restoreLiveSnapshot(previous);
                app.StatusLabel.Text = "实验项目打开失败：" + string(errorInfo.message);
                uialert(app.UIFigure, string(errorInfo.message), "无法打开实验项目");
            end
        end

        function report = processExperiment(app, options)
            % 按共用设置处理全部截面；ROI只使用该截面自己的定义。
            arguments
                app
                options.ExportVideos (1, 1) logical = false
                options.ShowProgress (1, 1) logical = true
                options.CacheOnly (1, 1) logical = false
            end
            if isempty(app.Project) || app.IsBusy || app.IsBatchProcessing
                error("fUS:ExperimentNotReady", "请先打开实验并等待当前处理结束。");
            end
            if options.CacheOnly && options.ExportVideos
                error("fUS:CacheOnlyVideo", "ROI自动更新不导出视频。");
            end
            app.persistMetadata();
            originalKey = app.SectionKey;
            originalMode = app.CurrentViewMode;
            sections = app.Project.Data.Sections;
            count = numel(sections);
            report = table(string({sections.Name})', repmat("未处理", count, 1), ...
                strings(count, 1), strings(count, 1), ...
                VariableNames=["Section", "Status", "OutputFolder", "Message"]);
            runName = "批处理_" + string(datetime("now", Format="yyyyMMdd_HHmmss_SSS"));
            app.stopPlayback();
            app.IsBatchProcessing = true;
            cleanup = onCleanup(@()app.finishBatch(originalKey, originalMode));
            progress = [];
            if options.ShowProgress
                title = "统一处理实验截面";
                if options.CacheOnly
                    title = "更新ROI总览 · 全部截面";
                end
                progress = uiprogressdlg(app.UIFigure, Title=title, ...
                    Message="准备中...", Cancelable="on", Value=0);
            end
            progressCleanup = onCleanup(@()app.deleteIfValid(progress));
            for index = 1:count
                if ~app.batchProgress(progress, index, count, 0)
                    break
                end
                try
                    if options.CacheOnly
                        state = app.Project.state(string(sections(index).Key));
                        if isempty(state) || ~isfield(state, "ROIs") || isempty(state.ROIs)
                            report.Status(index) = "无ROI";
                            continue
                        end
                    end
                    app.sectionChanged(string(sections(index).Key));
                    if app.SectionKey ~= string(sections(index).Key) || ~app.IsBaselineValid
                        error("fUS:BatchBaselineFailed", "截面或baseline未能载入，请检查源数据和baseline范围。");
                    end
                    app.IsBusy = true;
                    sectionCleanup = onCleanup(@()app.finishBusy());
                    if ~isempty(app.ROIs)
                        masks = arrayfun(@(roi)roi.Mask, app.ROIs, UniformOutput=false);
                        parameters = app.cbvParameters();
                        [times, curves] = fus.CBVEngine.calculateROICurves( ...
                            app.Sequence, app.Baseline, masks, parameters, app.ActualFPSField.Value, ...
                            @(frame, frames)app.batchProgress(progress, index, count, frame/frames));
                        app.ROICurveTimes = times;
                        app.ROICurveValues = curves;
                        app.ROICurveValid = true(1, numel(app.ROIs));
                        app.ROICurveParameters = parameters;
                        app.ROICurveFPS = app.ActualFPSField.Value;
                    end
                    if ~options.CacheOnly
                        outputFolder = fullfile(app.ResultFolder, runName);
                        mkdir(outputFolder);
                        result = struct(SourceFolder=app.DataFolder, ...
                            Configuration=app.collectConfiguration(), ...
                            ExperimentPlan=app.ExperimentPlan, Baseline=app.Baseline, ...
                            ROIs=app.ROIs, Unit=app.currentUnit(), ...
                            Times=app.ROICurveTimes, Curves=app.ROICurveValues);
                        save(fullfile(outputFolder, "analysis.mat"), "result", "-v7.3");
                        if ~isempty(app.ROIs)
                            app.writeROICurves(outputFolder);
                        end
                        report.OutputFolder(index) = outputFolder;
                    end
                    clear sectionCleanup
                    app.persistMetadata();
                    report.Status(index) = "完成";
                    if isempty(app.ROIs)
                        report.Message(index) = "已计算baseline；本截面未画ROI，未生成ROI曲线";
                    else
                        report.Message(index) = sprintf("已计算%d个ROI", numel(app.ROIs));
                    end
                catch errorInfo
                    clear sectionCleanup
                    if any(strcmp(errorInfo.identifier, ["fUS:ROICurveCancelled", "fUS:BatchCancelled"]))
                        report.Status(index) = "已取消";
                        report.Message(index) = "已完成截面的结果保留";
                        break
                    end
                    report.Status(index) = "失败";
                    report.Message(index) = string(errorInfo.message);
                end
            end
            % 先完成所有截面的曲线，再统一导出，确保每个视频引用同一套结果。
            if options.ExportVideos
                report.Status(report.Status == "完成") = "分析完成，视频待导出";
                for index = 1:count
                    if ~app.batchProgress(progress, index, count, 0)
                        break
                    end
                    if report.Status(index) ~= "分析完成，视频待导出"
                        continue
                    end
                    try
                        app.sectionChanged(string(sections(index).Key));
                        app.CurrentViewMode = "cbv";
                        app.ViewModeDropDown.Value = "cbv";
                        app.exportVideoToPath(fullfile(report.OutputFolder(index), "CBV.mp4"), ...
                            ShowProgress=false, ...
                            ProgressFcn=@(frame, frames)app.batchProgress( ...
                                progress, index, count, frame/frames));
                        report.Status(index) = "完成";
                    catch errorInfo
                        report.Status(index) = "视频未完成";
                        report.Message(index) = string(errorInfo.message);
                        if strcmp(errorInfo.identifier, "fUS:BatchCancelled")
                            break
                        end
                    end
                end
            end
            if ~options.CacheOnly
                summaryFolder = fileparts(app.Project.resultFolder("."));
                if ~isfolder(summaryFolder)
                    mkdir(summaryFolder);
                end
                writetable(report, fullfile(summaryFolder, runName + ".csv"), Encoding="UTF-8");
            end
            clear progressCleanup cleanup
            if options.CacheOnly
                app.StatusLabel.Text = sprintf("ROI总览：%d个截面已更新，%d失败，%d未完成；无ROI截面已跳过", ...
                    nnz(report.Status == "完成"), nnz(report.Status == "失败"), ...
                    nnz(ismember(report.Status, ["未处理", "已取消"])));
            else
                app.StatusLabel.Text = sprintf("批处理：%d完成，%d失败；汇总已保存", ...
                    nnz(report.Status == "完成"), nnz(report.Status == "失败"));
            end
        end

        %% 实验项目：共用配置、截面切换和自动保存
        function chooseExperimentFolder(app)
            folder = uigetdir(pwd, "选择包含多个截面的实验根目录");
            if ~isequal(folder, 0)
                app.openExperiment(string(folder));
            end
        end

        function succeeded = sectionChanged(app, key)
            succeeded = false;
            if isempty(app.Project) || app.IsBusy || app.IsRestoringMetadata || app.IsSelectingROI
                return
            end
            key = string(key);
            sections = app.Project.Data.Sections;
            index = find(string({sections.Key}) == key, 1);
            if isempty(index)
                return
            end
            previousKey = app.SectionKey;
            previous = app.captureLiveSnapshot();
            try
                app.persistMetadata();
                app.IsRestoringMetadata = true;
                cleanup = onCleanup(@()app.finishMetadataRestore());
                state = app.Project.state(key);
                sourceType = app.fieldOr(state, "DataSourceType", sections(index).DataSourceType);
                [configuration, plan] = app.Project.settings(sourceType);
                app.applyConfiguration(configuration);
                app.ExperimentPlan = plan;
                app.ExperimentPlanTable.Data = plan;
                if ~app.loadDataFolder(sections(index).DataFolder, ...
                        sourceType, true, false)
                    return
                end
                app.SectionKey = key;
                app.SectionDropDown.Value = key;
                app.SequenceFingerprint = fus.ExperimentStore.fingerprint( ...
                    app.DataFolder, app.DataSourceType);
                app.restoreSectionState(state);
                app.setResultFolder(app.Project.resultFolder(key));
                app.refreshAll();
                clear cleanup
                app.persistMetadata();
                app.updateExperimentStatus();
                app.updateComparisonControls();
                app.renderROICurves();
                succeeded = true;
            catch errorInfo
                app.restoreLiveSnapshot(previous);
                if strlength(previousKey) > 0
                    app.SectionDropDown.Value = previousKey;
                end
                app.StatusLabel.Text = "截面切换失败：" + string(errorInfo.message);
                if app.IsBatchProcessing
                    rethrow(errorInfo);
                end
                uialert(app.UIFigure, string(errorInfo.message), "截面切换失败");
            end
        end

        function restoreSectionState(app, state)
            app.BrainMaskCheckBox.Value = false;
            identityMatches = ~isempty(state) && isfield(state, "Fingerprint") ...
                && isequaln(state.Fingerprint, app.SequenceFingerprint);
            if ~isempty(state)
                if isfield(state, "Configuration")
                    app.applyConfiguration(state.Configuration);
                    app.LockedRatio = app.WidthField.Value/app.HeightField.Value;
                end
                if isfield(state, "ROIs") && ~isempty(state.ROIs)
                    imageSize = size(app.readFrame(1));
                    if all(arrayfun(@(roi)isequal(size(roi.Mask), imageSize(1:2)), state.ROIs))
                        app.ROIs = state.ROIs;
                        app.ROISelectedIndex = min(numel(app.ROIs), ...
                            max(0, app.fieldOr(state, "ROISelectedIndex", 0)));
                        app.resetROICurveCache();
                        app.updateROIStatus();
                    end
                end
                if isfield(state, "Bookmarks")
                    app.Bookmarks = state.Bookmarks;
                    app.BookmarkTable.Data = app.Bookmarks;
                end
                if isfield(state, "UserDisplayMask") ...
                        && isequal(size(state.UserDisplayMask), size(app.Sequence.readGray(1)))
                    app.UserDisplayMask = state.UserDisplayMask;
                    app.UserDisplayMaskVertices = app.fieldOr(state, "UserDisplayMaskVertices", []);
                end
                app.CurrentIndex = min(numel(app.Files), ...
                    max(1, round(app.fieldOr(state, "CurrentIndex", 1))));
                app.TimelineSlider.Value = app.CurrentIndex;
            end
            signature = app.analysisSignature();
            canRestoreBaseline = identityMatches && isfield(state, "Baseline") ...
                && ~isempty(fieldnames(state.Baseline)) ...
                && isequaln(app.fieldOr(state, "AnalysisSignature", struct()), signature);
            if canRestoreBaseline
                app.Baseline = state.Baseline;
                app.BaselineGray = app.Baseline.Gray;
                app.AnalysisMask = app.Baseline.AnalysisMask;
                app.IsBaselineValid = true;
                app.SaveCBVButton.Enable = "on";
                app.ExportCBVVideoButton.Enable = "on";
            else
                app.computeBaseline();
            end
            if app.IsBaselineValid && identityMatches && isfield(state, "ROICurveValues") ...
                    && isequaln(app.fieldOr(state, "AnalysisSignature", struct()), signature) ...
                    && size(state.ROICurveValues, 1) == numel(app.Files) ...
                    && size(state.ROICurveValues, 2) == numel(app.ROIs) ...
                    && isequaln(state.ROICurveParameters, app.cbvParameters()) ...
                    && state.ROICurveFPS == app.ActualFPSField.Value
                app.ROICurveTimes = state.ROICurveTimes;
                app.ROICurveValues = state.ROICurveValues;
                app.ROICurveValid = state.ROICurveValid;
                app.ROICurveParameters = state.ROICurveParameters;
                app.ROICurveFPS = state.ROICurveFPS;
            end
            app.applyAspect();
            app.drawDisplayMaskOverlay();
            app.renderROICurves();
        end

        function finishMetadataRestore(app)
            app.IsRestoringMetadata = false;
        end

        function snapshot = captureLiveSnapshot(app)
            % 仅保存可恢复的运行状态；数据加载成功后再提交项目切换。
            names = ["Project", "SectionKey", "Sequence", "Files", "DataFolder", ...
                "DataSourceType", "ResultFolder", "CurrentIndex", "OriginalRatio", ...
                "LockedRatio", "Bookmarks", "ExperimentPlan", "Baseline", ...
                "BaselineGray", "AnalysisMask", "IsBaselineValid", ...
                "CurrentCBVMap", "CurrentAverageIndices", "SequenceFingerprint", ...
                "UserDisplayMask", "UserDisplayMaskVertices", ...
                "ComparisonSelectedKeys", "ComparisonCache", ...
                "ROIs", "ROISelectedIndex", "ROICurveTimes", "ROICurveValues", ...
                "ROICurveValid", "ROICurveParameters", "ROICurveFPS"];
            snapshot = struct();
            for name = names
                snapshot.(name) = app.(name);
            end
            snapshot.Configuration = app.collectConfiguration();
            snapshot.DataLabel = app.DataFolderLabel.Text;
        end

        function restoreLiveSnapshot(app, snapshot)
            app.IsRestoringMetadata = true;
            cleanup = onCleanup(@()app.finishMetadataRestore());
            fields = fieldnames(snapshot);
            for index = 1:numel(fields)
                if ~any(string(fields{index}) == ["Configuration", "DataLabel"])
                    app.(fields{index}) = snapshot.(fields{index});
                end
            end
            app.applyConfiguration(snapshot.Configuration);
            app.CBVBackgroundRGB = [];
            app.ExperimentPlanTable.Data = app.ExperimentPlan;
            app.BookmarkTable.Data = app.Bookmarks;
            app.DataFolderLabel.Text = snapshot.DataLabel;
            app.ResultFolderLabel.Text = app.compactPath(app.ResultFolder);
            if ~isempty(app.Project)
                sections = app.Project.Data.Sections;
                app.SectionDropDown.Items = string({sections.Name});
                app.SectionDropDown.ItemsData = string({sections.Key});
                app.SectionDropDown.Enable = "on";
                if strlength(app.SectionKey) > 0
                    app.SectionDropDown.Value = app.SectionKey;
                end
                app.updateExperimentStatus();
            else
                app.SectionDropDown.Items = "尚未载入实验";
                app.SectionDropDown.ItemsData = "";
                app.SectionDropDown.Value = "";
                app.SectionDropDown.Enable = "off";
            end
            if ~isempty(app.Files)
                app.TimelineSlider.Limits = [1, max(2, numel(app.Files))];
                app.TimelineSlider.Value = app.CurrentIndex;
            end
            app.updateROIStatus();
            app.updateComparisonControls();
            app.applyAspect();
            app.SaveCBVButton.Enable = matlab.lang.OnOffSwitchState(app.IsBaselineValid);
            app.ExportCBVVideoButton.Enable = matlab.lang.OnOffSwitchState(app.IsBaselineValid);
            app.refreshAll();
            app.renderROICurves();
            clear cleanup
        end

        function scheduleMetadataSave(app)
            app.MetadataNeedsSave = true;
        end

        function autosaveMetadata(app)
            if app.IsBusy || app.IsRestoringMetadata || app.IsSelectingROI ...
                    || app.IsBatchProcessing || isempty(app.Project) ...
                    || strcmp(app.PlaybackTimer.Running, "on")
                return
            end
            try
                app.persistMetadata();
            catch errorInfo
                app.MetadataNeedsSave = true;
                app.ExperimentStatusLabel.Text = ...
                    "自动保存未成功：" + string(errorInfo.message) + "。请检查结果盘。";
            end
        end

        function persistMetadata(app)
            if isempty(app.Project) || strlength(app.SectionKey) == 0 ...
                    || isempty(app.Files) || app.IsRestoringMetadata
                return
            end
            configuration = app.collectConfiguration();
            localConfiguration = struct(Width=configuration.Width, ...
                Height=configuration.Height, LockRatio=configuration.LockRatio, ...
                BrainMask=configuration.BrainMask);
            baseline = struct();
            if app.IsBaselineValid
                baseline = app.Baseline;
            end
            state = struct(Configuration=localConfiguration, DataSourceType=app.DataSourceType, ...
                CurrentIndex=app.CurrentIndex, ROIs=app.ROIs, ...
                UserDisplayMask=app.UserDisplayMask, ...
                UserDisplayMaskVertices=app.UserDisplayMaskVertices, ...
                ROISelectedIndex=app.ROISelectedIndex, Bookmarks=app.BookmarkTable.Data, ...
                Fingerprint=app.SequenceFingerprint, Baseline=baseline, ...
                AnalysisSignature=app.analysisSignature(), ...
                ROICurveTimes=app.ROICurveTimes, ROICurveValues=app.ROICurveValues, ...
                ROICurveValid=app.ROICurveValid, ...
                ROICurveParameters=app.ROICurveParameters, ROICurveFPS=app.ROICurveFPS);
            app.Project.remember(app.SectionKey, state, configuration, app.currentExperimentPlan());
            changed = app.Project.save();
            wasPending = app.MetadataNeedsSave;
            app.MetadataNeedsSave = false;
            if changed || wasPending
                app.updateExperimentStatus();
            end
        end

        function signature = analysisSignature(app)
            signature = struct(Parameters=app.cbvParameters(), ...
                ActualFPS=app.ActualFPSField.Value, ...
                BaselineSeconds=[app.BaselineStartField.Value, app.BaselineEndField.Value]);
        end

        function updateExperimentStatus(app)
            if isempty(app.Project)
                return
            end
            [~, name] = fileparts(app.Project.RootFolder);
            app.ExperimentStatusLabel.Text = sprintf( ...
                "%s · %d个截面 · 配置共用 / ROI独立 · 自动保存", ...
                name, numel(app.Project.Data.Sections));
            app.ExperimentStatusLabel.Tooltip = fus.ExperimentStore.projectPath(app.Project.RootFolder);
        end

        function batchProcessSections(app)
            if isempty(app.Project) || app.IsBusy || app.IsBatchProcessing
                return
            end
            choice = uiconfirm(app.UIFigure, ...
                "全部截面共用当前帧率、CBV参数和实验计划。ROI按截面独立使用。请选择输出内容。", ...
                "批量处理整个实验", Options=["baseline和ROI曲线", "同时导出CBV视频", "取消"], ...
                DefaultOption=1, CancelOption=3);
            if choice == "取消"
                return
            end
            try
                app.processExperiment(ExportVideos=choice == "同时导出CBV视频");
            catch errorInfo
                uialert(app.UIFigure, string(errorInfo.message), "批处理未完成");
            end
        end

        function proceed = batchProgress(~, progress, index, count, fraction)
            proceed = true;
            if isempty(progress) || ~isvalid(progress)
                return
            end
            progress.Value = min(1, (index-1+fraction)/count);
            progress.Message = sprintf("截面 %d / %d · %.0f%%", index, count, 100*fraction);
            drawnow limitrate;
            proceed = ~progress.CancelRequested;
        end

        function finishBatch(app, originalKey, originalMode)
            app.IsBusy = false;
            app.IsBatchProcessing = false;
            app.sectionChanged(originalKey);
            app.CurrentViewMode = originalMode;
            app.ViewModeDropDown.Value = originalMode;
            app.refreshAll();
        end

        function exportROICurves(app)
            if isempty(app.ROIs) || app.IsBusy || app.IsBatchProcessing
                app.StatusLabel.Text = "请先添加ROI并等待当前处理结束";
                return
            end
            if ~all(app.ROICurveValid)
                app.showROICurves();
            end
            if isempty(app.ROICurveValues) || ~all(app.ROICurveValid)
                return
            end
            folder = uigetdir(app.ResultFolder, "选择ROI曲线输出目录（CSV和MAT）");
            if isequal(folder, 0)
                return
            end
            outputFolder = fullfile(string(folder), ...
                "ROI导出_" + string(datetime("now", Format="yyyyMMdd_HHmmss_SSS")));
            mkdir(outputFolder);
            app.writeROICurves(outputFolder);
            app.persistMetadata();
            app.StatusLabel.Text = "ROI曲线已导出为CSV和MAT（含名称、单位和参数）";
        end

        function writeROICurves(app, folder)
            names = string({app.ROIs.Name});
            variableNames = matlab.lang.makeUniqueStrings(["Time_s", names]);
            values = array2table([app.ROICurveTimes, app.ROICurveValues], ...
                VariableNames=variableNames);
            curves = struct(SourceFolder=app.DataFolder, Times=app.ROICurveTimes, ...
                Values=app.ROICurveValues, ROINames=names, ROIs=app.ROIs, ...
                Unit=app.currentUnit(), Configuration=app.collectConfiguration(), ...
                ExperimentPlan=app.ExperimentPlan);
            writetable(values, fullfile(folder, "ROI曲线.csv"), Encoding="UTF-8");
            save(fullfile(folder, "ROI曲线.mat"), "curves", "-v7.3");
        end

    end
end
