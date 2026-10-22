classdef fUSWorkspaceComparisonWorkflow
    %FUSWORKSPACECOMPARISONWORKFLOW 同步截面画面和跨截面ROI曲线。
    % 每个截面的ROI留在自己的数据坐标中，只在共同时间轴上比较曲线。

    methods (Static)
        function updateControls(app)
            if isempty(app.Project)
                return
            end
            sections = app.Project.Data.Sections;
            keys = string({sections.Key});
            names = erase(string({sections.Name}), "/SVD");
            app.SectionListBox.Items = names;
            app.SectionListBox.ItemsData = keys;
            app.SectionListBox.Enable = "on";
            selected = app.ComparisonSelectedKeys(ismember(app.ComparisonSelectedKeys, keys));
            if isempty(selected)
                selected = app.SectionKey;
            end
            selected = fUSWorkspaceComparisonWorkflow.includeEditor(selected, app.SectionKey);
            selected = selected(1:min(4, numel(selected)));
            app.ComparisonSelectedKeys = selected;
            app.SectionListBox.Value = selected;
            app.refreshCrossROIOverview();
            app.refreshComparisonFrames();
            if numel(fUSWorkspaceComparisonWorkflow.visibleKeys(app)) < numel(selected)
                app.StatusLabel.Text = "CBV对照仅显示单位一致的截面；不同单位可切换原始图像比较";
            end
        end

        function selectionChanged(app, keys)
            if isempty(app.Project) || app.IsBusy || app.IsBatchProcessing
                return
            end
            keys = reshape(string(keys), 1, []);
            keys = fUSWorkspaceComparisonWorkflow.includeEditor(keys, app.SectionKey);
            previous = reshape(app.ComparisonSelectedKeys, 1, []);
            keys = [previous(ismember(previous, keys)), keys(~ismember(keys, previous))];
            if numel(keys) > 4
                app.StatusLabel.Text = "同时对照最多4个截面；全部ROI仍保留在实验总览中";
                keys = keys(1:4);
            end
            app.ComparisonSelectedKeys = keys;
            app.SectionListBox.Value = keys;
            app.refreshComparisonFrames();
            if numel(fUSWorkspaceComparisonWorkflow.visibleKeys(app)) < numel(keys)
                app.StatusLabel.Text = "CBV对照仅显示单位一致的截面；不同单位可切换原始图像比较";
            end
            app.scheduleMetadataSave();
        end

        function keys = visibleKeys(app)
            if isempty(app.Project) || strlength(app.SectionKey) == 0
                keys = strings(1, 0);
                return
            end
            selected = reshape(app.ComparisonSelectedKeys, 1, []);
            known = string({app.Project.Data.Sections.Key});
            selected = selected(ismember(selected, known));
            keys = fUSWorkspaceComparisonWorkflow.includeEditor(selected, app.SectionKey);
            keys = keys(1:min(4, numel(keys)));
            if app.CurrentViewMode == "cbv"
                keep = true(size(keys));
                sections = app.Project.Data.Sections;
                for index = 1:numel(keys)
                    if keys(index) == app.SectionKey
                        continue
                    end
                    section = find(string({sections.Key}) == keys(index), 1);
                    state = app.Project.state(keys(index));
                    sourceType = app.fieldOr(state, "DataSourceType", sections(section).DataSourceType);
                    [configuration, ~] = fUSWorkspaceComparisonWorkflow.configuration(app, sourceType);
                    unit = fus.CBVEngine.unitLabel( ...
                        fUSWorkspaceComparisonWorkflow.parameters(configuration, sourceType));
                    keep(index) = unit == app.currentUnit();
                end
                keys = keys(keep);
            end
        end

        function refreshFrames(app)
            if app.IsUpdatingComparison || isempty(app.Project) || isempty(app.Files) ...
                    || app.IsSelectingROI || app.IsRestoringMetadata || app.IsBatchProcessing
                return
            end
            app.IsUpdatingComparison = true;
            cleanup = onCleanup(@()fUSWorkspaceComparisonWorkflow.finishUpdate(app));
            keys = fUSWorkspaceComparisonWorkflow.visibleKeys(app);
            if app.IsImageFocused
                keys = app.SectionKey;
            end
            count = numel(keys);
            if count < 2
                app.ComparisonGrid.ColumnWidth = {"1x", 0};
                app.ComparisonGrid.RowHeight = {"1x", 0};
            elseif count == 2
                app.ComparisonGrid.ColumnWidth = {"1x", "1x"};
                app.ComparisonGrid.RowHeight = {"1x", 0};
            else
                app.ComparisonGrid.ColumnWidth = {"1x", "1x"};
                app.ComparisonGrid.RowHeight = {"1x", "1x"};
            end
            app.ImagePanel.Title = fUSWorkspaceComparisonWorkflow.panelTitle( ...
                app.SectionKey, app.CurrentViewMode) + " · 正在标注";
            editorSlot = find(keys == app.SectionKey, 1);
            app.ImagePanel.Layout.Row = 1 + (editorSlot > 2);
            app.ImagePanel.Layout.Column = 1 + mod(editorSlot-1, 2);
            otherSlots = find(keys ~= app.SectionKey);
            for index = 1:3
                if index > numel(app.ComparisonCards)
                    panel = uipanel(app.ComparisonGrid, BackgroundColor=[0.025, 0.03, 0.04], ...
                        ForegroundColor=[0.88, 0.90, 0.93]);
                    grid = uigridlayout(panel, [1, 1], Padding=[3, 3, 3, 3], ...
                        BackgroundColor=[0.025, 0.03, 0.04]);
                    axesHandle = uiaxes(grid, Color=[0.025, 0.03, 0.04], ...
                        XTick=[], YTick=[], YDir="reverse", Box="off");
                    axesHandle.Toolbar.Visible = "off";
                    disableDefaultInteractivity(axesHandle);
                    app.ComparisonCards{index} = struct(Panel=panel, Axes=axesHandle, Image=[]);
                end
                card = app.ComparisonCards{index};
                card.Panel.Visible = matlab.lang.OnOffSwitchState(index < count);
                if index >= count
                    continue
                end
                slot = otherSlots(index);
                card.Panel.Layout.Row = 1 + (slot > 2);
                card.Panel.Layout.Column = 1 + mod(slot-1, 2);
                key = keys(slot);
                try
                    [frame, roiList, context] = fUSWorkspaceComparisonWorkflow.frameAtTime( ...
                        app, key, app.frameTime(app.CurrentIndex));
                    if isempty(card.Image) || ~isvalid(card.Image)
                        card.Image = image(card.Axes, CData=frame);
                        card.Axes.XTick = [];
                        card.Axes.YTick = [];
                    else
                        card.Image.CData = frame;
                    end
                    card.Image.Visible = "on";
                    card.Image.ButtonDownFcn = @(~, ~)app.activateSection(key);
                    card.Panel.ButtonDownFcn = @(~, ~)app.activateSection(key);
                    imageSize = size(frame);
                    card.Image.XData = [0, imageSize(2)];
                    card.Image.YData = [0, imageSize(1)];
                    xlim(card.Axes, [0, imageSize(2)]);
                    ylim(card.Axes, [0, imageSize(1)]);
                    pbaspect(card.Axes, [imageSize(2), imageSize(1), 1]);
                    delete(findall(card.Axes, Tag="ComparisonROI"));
                    hold(card.Axes, "on");
                    for roiIndex = 1:numel(roiList)
                        if ~roiList(roiIndex).Visible
                            continue
                        end
                        position = roiList(roiIndex).NormalizedPosition .* imageSize([2, 1]);
                        position = [position; position(1, :)]; %#ok<AGROW>
                        plot(card.Axes, position(:, 1), position(:, 2), ...
                            Color=fUSWorkspaceComparisonWorkflow.roiColor(key, roiIndex), ...
                            LineWidth=0.65, Tag="ComparisonROI", HitTest="off");
                    end
                    hold(card.Axes, "off");
                    card.Panel.Title = fUSWorkspaceComparisonWorkflow.panelTitle(key, app.CurrentViewMode) ...
                        + " · 点击标注";
                    if ~isempty(context.UserMaskVertices)
                        points = context.UserMaskVertices .* imageSize([2, 1]);
                        points = [points; points(1, :)]; %#ok<AGROW>
                        hold(card.Axes, "on");
                        plot(card.Axes, points(:, 1), points(:, 2), "w--", ...
                            LineWidth=1, Tag="ComparisonROI", HitTest="off");
                        hold(card.Axes, "off");
                    end
                catch errorInfo
                    if ~isempty(card.Image) && isvalid(card.Image)
                        card.Image.Visible = "off";
                    end
                    delete(findall(card.Axes, Tag="ComparisonROI"));
                    card.Panel.Title = erase(key, "/SVD") + " · 无法显示";
                    card.Panel.Tooltip = string(errorInfo.message);
                end
                app.ComparisonCards{index} = card;
            end
            clear cleanup
        end

        function updateROIOverview(app)
            keys = strings(0, 1);
            sections = strings(0, 1);
            names = strings(0, 1);
            status = strings(0, 1);
            indices = zeros(0, 1);
            if ~isempty(app.Project)
                allSections = app.Project.Data.Sections;
                for section = 1:numel(allSections)
                    key = string(allSections(section).Key);
                    state = fUSWorkspaceComparisonWorkflow.sectionState(app, key);
                    if isempty(state) || ~isfield(state, "ROIs")
                        continue
                    end
                    for index = 1:numel(state.ROIs)
                        keys(end + 1, 1) = key; %#ok<AGROW>
                        sections(end + 1, 1) = erase(string(allSections(section).Name), "/SVD"); %#ok<AGROW>
                        names(end + 1, 1) = string(state.ROIs(index).Name); %#ok<AGROW>
                        indices(end + 1, 1) = index; %#ok<AGROW>
                        isValid = isfield(state, "ROICurveValid") ...
                            && index <= numel(state.ROICurveValid) && state.ROICurveValid(index);
                        if isValid && fUSWorkspaceComparisonWorkflow.compatible(app, key, state)
                            status(end + 1, 1) = "已计算"; %#ok<AGROW>
                        else
                            status(end + 1, 1) = "待更新"; %#ok<AGROW>
                        end
                    end
                end
            end
            app.CrossROITable.Data = table(keys, sections, names, status, indices, ...
                VariableNames=["SectionKey", "Section", "ROI", "Status", "ROIIndex"]);
        end

        function specs = curveSpecs(app)
            specs = struct("Name", {}, "Times", {}, "Values", {}, "Color", {}, ...
                "Unit", {}, "SectionKey", {}, "ROIIndex", {});
            if isempty(app.Project) || ~app.ShowAllSectionsCheckBox.Value
                return
            end
            sections = app.Project.Data.Sections;
            compared = fUSWorkspaceComparisonWorkflow.visibleKeys(app);
            for section = 1:numel(sections)
                key = string(sections(section).Key);
                if key == app.SectionKey || ~any(compared == key)
                    continue
                end
                state = app.Project.state(key);
                if isempty(state) || ~isfield(state, "ROIs") ...
                        || ~isfield(state, "ROICurveValues") || isempty(state.ROICurveValues) ...
                        || ~fUSWorkspaceComparisonWorkflow.compatible(app, key, state)
                    continue
                end
                sourceType = app.fieldOr(state, "DataSourceType", sections(section).DataSourceType);
                [configuration, ~] = fUSWorkspaceComparisonWorkflow.configuration(app, sourceType);
                unit = fus.CBVEngine.unitLabel(fUSWorkspaceComparisonWorkflow.parameters(configuration, sourceType));
                if unit ~= app.currentUnit()
                    continue
                end
                for index = 1:numel(state.ROIs)
                    if ~state.ROIs(index).Visible || index > numel(state.ROICurveValid) ...
                            || ~state.ROICurveValid(index)
                        continue
                    end
                    specs(end + 1) = struct( ...
                        Name=erase(string(sections(section).Name), "/SVD") + " · " + string(state.ROIs(index).Name), ...
                        Times=state.ROICurveTimes, Values=state.ROICurveValues(:, index), ...
                        Color=fUSWorkspaceComparisonWorkflow.roiColor(key, index), ...
                        Unit=unit, SectionKey=key, ROIIndex=index); %#ok<AGROW>
                end
            end
        end

        function roiSelected(app, event)
            if isempty(event.Indices) || app.IsBusy || app.IsBatchProcessing
                return
            end
            row = event.Indices(1, 1);
            data = app.CrossROITable.Data;
            if row > height(data)
                return
            end
            if data.SectionKey(row) ~= app.SectionKey
                if ~app.sectionChanged(data.SectionKey(row))
                    return
                end
            end
            app.selectROI(data.ROIIndex(row));
        end

        function curveClicked(app, key, index, event)
            if app.IsBusy || app.IsBatchProcessing
                return
            end
            seconds = event.IntersectionPoint(1);
            if key ~= app.SectionKey && ~app.sectionChanged(key)
                return
            end
            app.selectROI(index);
            app.sliderMoving(seconds*app.ActualFPSField.Value);
        end

        function color = roiColor(key, index)
            palette = [0.18, 0.50, 0.77; 0.89, 0.42, 0.20; 0.30, 0.68, 0.49; ...
                0.64, 0.45, 0.72; 0.85, 0.65, 0.19; 0.24, 0.65, 0.70; 0.83, 0.39, 0.55];
            values = double(char(string(key)));
            hash = sum(values.*(1:numel(values))) + 3*index;
            color = palette(1 + mod(hash, size(palette, 1)), :);
        end

        function [frames, titles, rois, masks] = exportImages(app, index)
            if isempty(app.Project)
                frames = {app.renderFrameForExport(index)};
                titles = "当前截面";
                rois = {app.ROIs};
                masks = {[]};
                if app.BrainMaskCheckBox.Value
                    masks = {app.UserDisplayMaskVertices};
                end
                return
            end
            keys = fUSWorkspaceComparisonWorkflow.visibleKeys(app);
            frames = cell(1, numel(keys));
            titles = strings(1, numel(keys));
            rois = cell(1, numel(keys));
            masks = cell(1, numel(keys));
            seconds = app.frameTime(index);
            for panel = 1:numel(keys)
                key = keys(panel);
                if key == app.SectionKey
                    frames{panel} = app.renderFrameForExport(index);
                    rois{panel} = app.ROIs;
                    masks{panel} = app.UserDisplayMaskVertices;
                    if ~app.BrainMaskCheckBox.Value
                        masks{panel} = [];
                    end
                else
                    [frames{panel}, rois{panel}, context] = ...
                        fUSWorkspaceComparisonWorkflow.frameAtTime(app, key, seconds);
                    masks{panel} = context.UserMaskVertices;
                end
                for roi = 1:numel(rois{panel})
                    rois{panel}(roi).Color = fUSWorkspaceComparisonWorkflow.roiColor(key, roi);
                end
                titles(panel) = erase(key, "/SVD");
            end
        end

        function configuration = reportConfiguration(app)
            [~, titles, rois, masks] = fUSWorkspaceComparisonWorkflow.exportImages(app, 1);
            curves = struct("Name", {}, "Times", {}, "Values", {}, "Color", {}, "Unit", {});
            for index = 1:numel(app.ROIs)
                if ~app.ROIs(index).Visible || index > numel(app.ROICurveValid) ...
                        || ~app.ROICurveValid(index) || isempty(app.ROICurveTimes)
                    continue
                end
                curves(end + 1) = struct( ...
                    Name=erase(app.SectionKey, "/SVD") + " · " + string(app.ROIs(index).Name), ...
                    Times=app.ROICurveTimes, Values=app.ROICurveValues(:, index), ...
                    Color=fUSWorkspaceComparisonWorkflow.roiColor(app.SectionKey, index), ...
                    Unit=app.currentUnit()); %#ok<AGROW>
            end
            external = app.crossSectionCurveSpecs();
            visible = fUSWorkspaceComparisonWorkflow.visibleKeys(app);
            external = external(ismember(string({external.SectionKey}), visible));
            for index = 1:numel(external)
                curves(end + 1) = struct(Name=external(index).Name, ...
                    Times=external(index).Times, Values=external(index).Values, ...
                    Color=external(index).Color, Unit=external(index).Unit); %#ok<AGROW>
            end
            if string(app.ConversionDropDown.Value) == "unknown"
                unit = "Δlog灰度";
            else
                unit = "%ΔPD";
            end
            configuration = struct(ImageTitles=titles, Curves=curves, ...
                ExperimentPlan=app.currentExperimentPlan(), ...
                DisplayLimit=app.HighThresholdField.Value, Unit=unit, ...
                ROIs={rois}, MaskVertices={masks}, ...
                ColorMap=fus.FrameRenderer.blueWhiteRed(256), ...
                ShowColorbar=app.CurrentViewMode == "cbv", ...
                Duration=numel(app.Files)/app.ActualFPSField.Value, ...
                Title="fUS · Power Doppler response");
            configuration.Layout = app.ReportLayout;
            configuration.CurveFraction = app.ReportCurveFraction;
            configuration.FrameSize = app.ReportFrameSize;
            configuration.ShowROILabels = app.ReportShowROILabels;
            keys = fUSWorkspaceComparisonWorkflow.visibleKeys(app);
            sources = struct("SectionKey", {}, "DataFolder", {}, "Fingerprint", {}, ...
                "AnalysisSignature", {}, "UserDisplayMask", {});
            if isempty(app.Project)
                configuration.ExperimentRoot = app.DataFolder;
                configuration.SourceSections = sources;
                return
            end
            sections = app.Project.Data.Sections;
            for index = 1:numel(keys)
                section = find(string({sections.Key}) == keys(index), 1);
                state = app.Project.state(keys(index));
                sourceType = app.fieldOr(state, "DataSourceType", sections(section).DataSourceType);
                [~, signature] = fUSWorkspaceComparisonWorkflow.configuration(app, sourceType);
                mask = app.fieldOr(state, "UserDisplayMask", []);
                if keys(index) == app.SectionKey
                    signature = app.analysisSignature();
                    mask = app.UserDisplayMask;
                end
                sources(end + 1) = struct(SectionKey=keys(index), ...
                    DataFolder=string(sections(section).DataFolder), ...
                    Fingerprint=fus.ExperimentStore.fingerprint(sections(section).DataFolder, sourceType), ...
                    AnalysisSignature=signature, UserDisplayMask=mask); %#ok<AGROW>
            end
            configuration.ExperimentRoot = app.Project.RootFolder;
            configuration.SourceSections = sources;
        end
    end

    methods (Static, Access = private)
        function keys = includeEditor(keys, editor)
            % 选择标注对象不改变已有截面的显示位置。
            keys = unique(reshape(keys, 1, []), "stable");
            if ~ismember(editor, keys)
                if numel(keys) >= 4
                    keys(4) = editor;
                else
                    keys(end+1) = editor;
                end
            end
        end

        function finishUpdate(app)
            app.IsUpdatingComparison = false;
        end

        function title = panelTitle(key, mode)
            title = erase(key, "/SVD");
            if mode == "cbv"
                title = title + " · CBV";
            else
                title = title + " · 灰度原图";
            end
        end

        function state = sectionState(app, key)
            if key == app.SectionKey
                state = struct(ROIs=app.ROIs, ROICurveValid=app.ROICurveValid, ...
                    AnalysisSignature=app.analysisSignature(), DataSourceType=app.DataSourceType);
            else
                state = app.Project.state(key);
            end
        end

        function valid = compatible(app, key, state)
            valid = false;
            if ~isfield(state, "AnalysisSignature")
                return
            end
            sections = app.Project.Data.Sections;
            index = find(string({sections.Key}) == key, 1);
            if isempty(index)
                return
            end
            sourceType = app.fieldOr(state, "DataSourceType", sections(index).DataSourceType);
            [configuration, signature] = fUSWorkspaceComparisonWorkflow.configuration(app, sourceType);
            valid = isequaln(state.AnalysisSignature, signature);
            if key == app.SectionKey
                valid = valid && app.IsBaselineValid;
            elseif valid && isfield(state, "Fingerprint")
                valid = isequaln(state.Fingerprint, fus.ExperimentStore.fingerprint( ...
                    sections(index).DataFolder, sourceType));
            else
                valid = false;
            end
            % 保留configuration输出用于这里明确检验源数据的标定参数。
            valid = valid && isfinite(configuration.ActualFPS);
        end

        function [configuration, signature] = configuration(app, sourceType)
            [configuration, ~] = app.Project.settings(sourceType);
            live = app.collectConfiguration();
            sourceFields = ["ConversionMode", "DynamicRangeDb", "Log10PerGray", ...
                "MinimumBaselineGray", "DataSourceType", "Width", "Height", "LockRatio"];
            names = fieldnames(live);
            for index = 1:numel(names)
                if ~any(string(names{index}) == sourceFields)
                    configuration.(names{index}) = live.(names{index});
                end
            end
            if sourceType == app.DataSourceType
                for name = sourceFields(1:4)
                    configuration.(name) = live.(name);
                end
            end
            parameters = fUSWorkspaceComparisonWorkflow.parameters(configuration, sourceType);
            signature = struct(Parameters=parameters, ActualFPS=configuration.ActualFPS, ...
                BaselineSeconds=[configuration.BaselineStart, configuration.BaselineEnd]);
        end

        function parameters = parameters(configuration, sourceType)
            parameters = struct(SpatialAveragePixels=configuration.SpatialAverage, ...
                TemporalAverageFrames=configuration.TemporalAverage, ...
                ConversionMode=string(configuration.ConversionMode), ...
                DynamicRangeDb=configuration.DynamicRangeDb, ...
                Log10PerGray=configuration.Log10PerGray, ...
                MinimumBaselineGray=configuration.MinimumBaselineGray);
            if sourceType == "pdi"
                parameters.ConversionMode = "linear";
                parameters.MinimumBaselineGray = eps;
            end
        end

        function [frame, roiList, context] = frameAtTime(app, key, seconds)
            sections = app.Project.Data.Sections;
            index = find(string({sections.Key}) == key, 1);
            section = sections(index);
            state = app.Project.state(key);
            sourceType = app.fieldOr(state, "DataSourceType", section.DataSourceType);
            [configuration, signature] = fUSWorkspaceComparisonWorkflow.configuration(app, sourceType);
            fingerprint = fus.ExperimentStore.fingerprint(section.DataFolder, sourceType);
            cached = find(string({app.ComparisonCache.Key}) == key, 1);
            if isempty(cached) || ~isequaln(app.ComparisonCache(cached).Signature, signature) ...
                    || ~isequaln(app.ComparisonCache(cached).Fingerprint, fingerprint)
                if sourceType == "pdi"
                    sequence = fus.PDISequence(section.DataFolder, MaxCacheFrames=8);
                else
                    sequence = fus.ImageSequence(section.DataFolder, MaxCacheFrames=8);
                end
                fingerprint = fus.ExperimentStore.fingerprint(sequence.Folder, sourceType);
                if ~isempty(state) && isfield(state, "Baseline") ...
                        && isfield(state, "Fingerprint") && isfield(state, "AnalysisSignature") ...
                        && isequaln(state.Fingerprint, fingerprint) ...
                        && isequaln(state.AnalysisSignature, signature) ...
                        && ~isempty(fieldnames(state.Baseline))
                    baseline = state.Baseline;
                elseif app.CurrentViewMode == "cbv"
                    baseline = fus.CBVEngine.computeBaseline(sequence, signature.BaselineSeconds, ...
                        configuration.ActualFPS, signature.Parameters);
                else
                    baseline = struct();
                end
                entry = struct(Key=key, Sequence=sequence, Baseline=baseline, ...
                    Signature=signature, Fingerprint=fingerprint);
                if isempty(cached)
                    app.ComparisonCache(end + 1) = entry;
                    cached = numel(app.ComparisonCache);
                else
                    app.ComparisonCache(cached) = entry;
                end
            end
            data = app.ComparisonCache(cached);
            if app.CurrentViewMode == "cbv" && isempty(fieldnames(data.Baseline))
                data.Baseline = fus.CBVEngine.computeBaseline(data.Sequence, signature.BaselineSeconds, ...
                    configuration.ActualFPS, signature.Parameters);
                app.ComparisonCache(cached) = data;
            end
            roiList = app.fieldOr(state, "ROIs", ...
                struct("Name", {}, "Mask", {}, "NormalizedPosition", {}, "Visible", {}));
            local = app.fieldOr(state, "Configuration", struct());
            context = struct(UserMaskVertices=app.fieldOr(state, "UserDisplayMaskVertices", []));
            if ~app.fieldOr(local, "BrainMask", false)
                context.UserMaskVertices = [];
            end
            frameIndex = round(seconds*configuration.ActualFPS);
            if frameIndex < 1 || frameIndex > data.Sequence.frameCount()
                frame = zeros(size(data.Sequence.readFrame(1)), "uint8");
                frame = fus.FrameRenderer.drawTimestamp(frame, "此时刻无数据");
                return
            end
            if app.CurrentViewMode == "browser"
                frame = fus.FrameRenderer.colorizeOriginal(data.Sequence.readFrame(frameIndex), ...
                    string(app.BrowserColormapDropDown.Value));
            else
                [map, ~] = fus.CBVEngine.calculateMap(data.Sequence, data.Baseline, ...
                    frameIndex, signature.Parameters);
                display = app.displayParameters();
                display.UserMask = app.fieldOr(state, "UserDisplayMask", []);
                local = app.fieldOr(state, "Configuration", struct());
                display.BrainMask = app.fieldOr(local, "BrainMask", false);
                if ~isempty(display.UserMask) && ~isequal(size(display.UserMask), size(map))
                    display.UserMask = [];
                    context.UserMaskVertices = [];
                end
                display.ValidSignalMask = isfinite(data.Baseline.Gray) & data.Baseline.Gray > 0;
                frame = fus.FrameRenderer.renderCBV(map, data.Baseline.Gray, ...
                    data.Baseline.AnalysisMask, display);
            end
        end
    end
end
