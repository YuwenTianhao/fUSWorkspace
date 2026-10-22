classdef ReportRenderer < handle
    %REPORTRENDERER 同步展示图像、实验阶段与ROI响应的科研汇报画布。
    %
    % renderer = fus.ReportRenderer(configuration)
    % rgb = renderer.render({image1, image2}, seconds)
    %
    % 图像由调用者提供，本类不计算CBV、不读取数据，也不改变ROI数值。
    % 图形对象只创建一次，逐帧更新图像、已播放曲线和当前采样点。
    % 不推测解剖分区或毫米比例尺；所有单位来自调用者。

    properties (SetAccess = private)
        FrameSize (1, 2) double = [800, 1280]
    end

    properties (Access = private)
        Figure
        Config struct
        ImageAxes = gobjects(0)
        ImageHandles = gobjects(0)
        ImageTitleHandles = gobjects(0)
        CurveAxes
        PastHandles = gobjects(0)
        PointHandles = gobjects(0)
        TimeCursor
        TimeText
        PhaseText
        FontName string = "Arial"
        Background (1, 3) double = [0.035, 0.045, 0.060]
    end

    methods
        function renderer = ReportRenderer(configuration)
            arguments
                configuration (1, 1) struct
            end
            renderer.Config = fus.ReportRenderer.normalizeConfiguration(configuration);
            renderer.FrameSize = renderer.Config.FrameSize;
            renderer.FontName = fus.ReportRenderer.chooseFont();
            renderer.buildFigure();
        end

        function frame = render(renderer, imageFrames, seconds)
            arguments
                renderer
                imageFrames cell
                seconds (1, 1) double {mustBeFinite, mustBeNonnegative}
            end
            if numel(imageFrames) ~= numel(renderer.ImageHandles)
                error("fUS:ReportImageCount", "汇报帧的图像数量必须与ImageTitles一致。");
            end
            for index = 1:numel(imageFrames)
                frameImage = imageFrames{index};
                if isempty(frameImage)
                    renderer.ImageHandles(index).Visible = "off";
                    renderer.ImageTitleHandles(index).String = ...
                        renderer.Config.ImageTitles(index) + " · 无此时刻数据";
                    continue
                end
                if ~isnumeric(frameImage) || ndims(frameImage) ~= 3 ...
                        || size(frameImage, 3) ~= 3 || any(~isfinite(frameImage), "all")
                    error("fUS:ReportImageType", "汇报图像必须是有限值RGB数组。");
                end
                renderer.ImageHandles(index).CData = im2uint8(frameImage);
                renderer.ImageHandles(index).Visible = "on";
                renderer.ImageAxes(index).PlotBoxAspectRatio = ...
                    [size(frameImage, 2), size(frameImage, 1), 1];
                renderer.ImageTitleHandles(index).String = renderer.Config.ImageTitles(index);
            end
            for index = 1:numel(renderer.Config.Curves)
                curve = renderer.Config.Curves(index);
                shown = curve.Times <= seconds;
                renderer.PastHandles(index).XData = curve.Times(shown);
                renderer.PastHandles(index).YData = curve.Values(shown);
                sample = find(shown, 1, "last");
                if isempty(sample) || ~isfinite(curve.Values(sample)) ...
                        || seconds > curve.Times(end) + 1e-9
                    renderer.PointHandles(index).Visible = "off";
                else
                    renderer.PointHandles(index).XData = curve.Times(sample);
                    renderer.PointHandles(index).YData = curve.Values(sample);
                    renderer.PointHandles(index).Visible = "on";
                end
            end
            renderer.TimeCursor.Value = seconds;
            renderer.TimeText.String = sprintf("t = %.2f s", seconds);
            [phase, isStimulus] = renderer.phaseAt(seconds);
            renderer.PhaseText.String = phase;
            if isStimulus
                renderer.PhaseText.BackgroundColor = [0.56, 0.15, 0.12];
            else
                renderer.PhaseText.BackgroundColor = [0.10, 0.15, 0.21];
            end
            drawnow nocallbacks;
            % 固定纸张尺寸和分辨率，使无界面导出与屏幕缩放无关。
            frame = print(renderer.Figure, "-RGBImage", "-r100");
            if ~isequal(size(frame, [1, 2]), renderer.FrameSize)
                frame = imresize(frame, renderer.FrameSize);
            end
            frame = im2uint8(frame);
        end

        function figureHandle = getFigure(renderer)
            figureHandle = renderer.Figure;
        end

        function delete(renderer)
            if ~isempty(renderer.Figure) && isgraphics(renderer.Figure)
                delete(renderer.Figure);
            end
        end
    end

    methods (Access = private)
        function buildFigure(renderer)
            height = renderer.FrameSize(1);
            width = renderer.FrameSize(2);
            renderer.Figure = figure(Visible="off", Color=renderer.Background, ...
                Units="pixels", Position=[50, 50, width, height], ...
                MenuBar="none", ToolBar="none", NumberTitle="off", ...
                Name="fUS scientific report", ...
                PaperUnits="inches", PaperPosition=[0, 0, width/100, height/100], ...
                PaperSize=[width/100, height/100], PaperPositionMode="manual");
            % R2025a的打印器仍需此设置来保留暗色报告背景。
            renderer.Figure.InvertHardcopy = "off";
            set(renderer.Figure, DefaultTextInterpreter="none", ...
                DefaultAxesTickLabelInterpreter="none", ...
                DefaultTextFontName=renderer.FontName, DefaultAxesFontName=renderer.FontName);
            if isprop(renderer.Figure, "Theme")
                renderer.Figure.Theme = "dark";
            end
            renderer.buildHeader();
            renderer.buildImages();
            renderer.buildCurves();
        end

        function buildHeader(renderer)
            annotation(renderer.Figure, "textbox", [0.035, 0.938, 0.49, 0.045], ...
                String=renderer.Config.Title, Color=[0.88, 0.92, 0.97], ...
                FontName=renderer.FontName, FontSize=14, FontWeight="bold", ...
                EdgeColor="none", Margin=0, Interpreter="none");
            renderer.TimeText = annotation(renderer.Figure, "textbox", ...
                [0.565, 0.938, 0.145, 0.045], String="t = 0.00 s", ...
                Color="white", FontName=renderer.FontName, FontSize=14, ...
                EdgeColor="none", Margin=0, Interpreter="none", ...
                HorizontalAlignment="right");
            renderer.PhaseText = annotation(renderer.Figure, "textbox", ...
                [0.745, 0.934, 0.225, 0.055], String="", ...
                Color="white", FontName=renderer.FontName, FontSize=11, ...
                FontWeight="bold", EdgeColor="none", Margin=6, ...
                Interpreter="none", VerticalAlignment="middle");
            annotation(renderer.Figure, "line", [0.035, 0.97], [0.917, 0.917], ...
                Color=[0.20, 0.25, 0.32], LineWidth=0.6);
        end

        function buildImages(renderer)
            count = numel(renderer.Config.ImageTitles);
            renderer.ImageAxes = gobjects(1, count);
            renderer.ImageHandles = gobjects(1, count);
            renderer.ImageTitleHandles = gobjects(1, count);
            positions = renderer.imagePositions(count);
            colors = fus.ReportRenderer.defaultColors();
            for index = 1:count
                position = positions(index, :);
                axesHandle = axes(renderer.Figure, Units="normalized", ...
                    Position=position, Color=renderer.Background, ...
                    XLim=[0, 1], YLim=[0, 1], YDir="reverse", ...
                    XTick=[], YTick=[], Visible="off");
                renderer.ImageAxes(index) = axesHandle;
                hold(axesHandle, "on");
                renderer.ImageHandles(index) = image(axesHandle, ...
                    CData=zeros(8, 8, 3, "uint8"), XData=[0, 1], YData=[0, 1]);
                renderer.ImageTitleHandles(index) = title(axesHandle, ...
                    renderer.Config.ImageTitles(index), Color=[0.89, 0.92, 0.96], ...
                    FontSize=11, FontWeight="normal", Interpreter="none", ...
                    Visible="on");
                rois = renderer.Config.ROIs{index};
                for roiIndex = 1:numel(rois)
                    if isfield(rois, "Visible") && ~rois(roiIndex).Visible
                        continue
                    end
                    vertices = rois(roiIndex).NormalizedPosition;
                    if isempty(vertices)
                        continue
                    end
                    points = [vertices; vertices(1, :)];
                    color = colors(1+mod(roiIndex-1, size(colors, 1)), :);
                    if isfield(rois, "Color") && numel(rois(roiIndex).Color) == 3
                        color = rois(roiIndex).Color;
                    end
                    plot(axesHandle, points(:, 1), points(:, 2), ...
                        Color=color, LineWidth=0.7, HitTest="off");
                    if renderer.Config.ShowROILabels && isfield(rois, "Name")
                        text(axesHandle, vertices(1, 1), vertices(1, 2), ...
                            " " + string(rois(roiIndex).Name), Color=color, ...
                            FontSize=9, FontWeight="bold", ...
                            Interpreter="none", Clipping="on", ...
                            VerticalAlignment="bottom");
                    end
                end
                vertices = renderer.Config.MaskVertices{index};
                if ~isempty(vertices)
                    points = [vertices; vertices(1, :)];
                    plot(axesHandle, points(:, 1), points(:, 2), "--", ...
                        Color=[0.92, 0.92, 0.92], LineWidth=1.0, HitTest="off");
                end
                hold(axesHandle, "off");
            end
            if renderer.Config.ShowColorbar
                [~, ~, scalePosition] = renderer.regions();
                colorAxes = axes(renderer.Figure, Units="normalized", ...
                    Position=scalePosition, Visible="off");
                colormap(colorAxes, renderer.Config.ColorMap);
                clim(colorAxes, [-renderer.Config.DisplayLimit, renderer.Config.DisplayLimit]);
                scale = colorbar(colorAxes, "eastoutside");
                scale.Position = scalePosition;
                scale.Color = [0.86, 0.90, 0.95];
                scale.FontName = renderer.FontName;
                scale.FontSize = 10;
                scale.Box = "off";
                scale.Label.String = renderer.Config.Unit;
                scale.Label.Interpreter = "none";
                scale.Label.FontSize = 11;
            end
        end

        function buildCurves(renderer)
            [~, curvePosition] = renderer.regions();
            axesHandle = axes(renderer.Figure, Units="normalized", ...
                Position=curvePosition, PositionConstraint="innerposition", ...
                Color=renderer.Background, XColor=[0.8, 0.85, 0.91], ...
                YColor=[0.8, 0.85, 0.91], GridColor=[0.27, 0.32, 0.40], ...
                GridAlpha=0.35, Box="off", FontSize=10, ...
                XLim=[0, renderer.Config.Duration], Tag="fUSReportCurves");
            renderer.CurveAxes = axesHandle;
            hold(axesHandle, "on");
            curves = renderer.Config.Curves;
            count = numel(curves);
            renderer.PastHandles = gobjects(1, count);
            renderer.PointHandles = gobjects(1, count);
            values = vertcat(curves.Values);
            values = values(isfinite(values));
            if isempty(values)
                yLimits = [-1, 1];
            else
                spread = max(1, max(values)-min(values));
                yLimits = [min(0, min(values))-0.10*spread, max(0, max(values))+0.20*spread];
            end
            ylim(axesHandle, yLimits);
            renderer.drawPhaseBands(axesHandle, yLimits);
            yline(axesHandle, 0, ":", Color=[0.42, 0.48, 0.56], ...
                HandleVisibility="off", HitTest="off");
            for index = 1:count
                curve = curves(index);
                faint = 0.22*curve.Color + 0.78*renderer.Background;
                plot(axesHandle, curve.Times, curve.Values, Color=faint, ...
                    LineWidth=0.9, HandleVisibility="off", HitTest="off");
                renderer.PastHandles(index) = plot(axesHandle, NaN, NaN, ...
                    Color=curve.Color, LineWidth=1.7, DisplayName=curve.Name, ...
                    Tag="fUSReportElapsed", HitTest="off");
                renderer.PointHandles(index) = plot(axesHandle, NaN, NaN, ...
                    "o", Color="white", MarkerFaceColor=curve.Color, ...
                    MarkerEdgeColor="white", MarkerSize=6, LineWidth=0.8, ...
                    HandleVisibility="off", Visible="off", ...
                    Tag="fUSReportCurrentPoint", HitTest="off");
            end
            renderer.TimeCursor = xline(axesHandle, 0, ":", ...
                Color=[0.69, 0.74, 0.82], LineWidth=0.9, ...
                HandleVisibility="off", Tag="fUSReportTime", HitTest="off");
            xlabel(axesHandle, "Time (s)", Color=[0.85, 0.89, 0.94], FontSize=11);
            ylabel(axesHandle, renderer.Config.Unit, Color=[0.85, 0.89, 0.94], ...
                FontSize=11, Interpreter="none");
            title(axesHandle, "ROI response", Color=[0.91, 0.94, 0.98], ...
                FontSize=12, FontWeight="normal");
            grid(axesHandle, "on");
            if count > 0
                key = legend(axesHandle, renderer.PastHandles, string({curves.Name}), ...
                    Location="northoutside", TextColor=[0.86, 0.90, 0.95], ...
                    Color=renderer.Background, EdgeColor="none", ...
                    FontSize=8, Interpreter="none", NumColumns=1);
                key.Box = "off";
                if renderer.Config.Layout == "bottom"
                    key.NumColumns = min(3, count);
                    key.Units = "normalized";
                    key.Position = [0.075, curvePosition(2)+curvePosition(4)+0.035, ...
                        0.83, max(0.025, 0.022*ceil(count/3))];
                end
                % legend不能悄悄挤窄预览中已经选择的曲线区域。
                axesHandle.Position = curvePosition;
            else
                text(axesHandle, 0.5, 0.52, ["No valid ROI curves"; "Calculate curves before export"], ...
                    Units="normalized", HorizontalAlignment="center", ...
                    Color=[0.62, 0.69, 0.78], FontSize=10);
            end
            hold(axesHandle, "off");
            annotation(renderer.Figure, "textbox", [0.035, 0.025, 0.94, 0.03], ...
                String="fUS Workspace  |  ROI response  |  dots indicate current samples", ...
                Color=[0.47, 0.54, 0.64], FontName=renderer.FontName, FontSize=8, ...
                EdgeColor="none", Margin=0, Interpreter="none");
        end

        function drawPhaseBands(renderer, axesHandle, yLimits)
            plan = renderer.Config.ExperimentPlan;
            for index = 1:height(plan)
                if ~fus.ReportRenderer.isStimulus(string(plan.Label(index)))
                    continue
                end
                startTime = max(0, plan.Start_s(index));
                endTime = min(renderer.Config.Duration, plan.End_s(index));
                if endTime <= startTime
                    continue
                end
                patch(axesHandle, [startTime, endTime, endTime, startTime], ...
                    [yLimits(1), yLimits(1), yLimits(2), yLimits(2)], ...
                    [0.72, 0.23, 0.18], FaceAlpha=0.19, EdgeColor="none", ...
                    HandleVisibility="off", HitTest="off");
            end
        end

        function [phase, isStimulus] = phaseAt(renderer, seconds)
            phase = fus.ExperimentPlan.phaseAtNormalized(renderer.Config.ExperimentPlan, seconds);
            if strlength(phase) == 0
                phase = "实验计划外";
            end
            isStimulus = fus.ReportRenderer.isStimulus(phase);
        end

        function [imageRegion, curveRegion, scaleRegion] = regions(renderer)
            fraction = renderer.Config.CurveFraction;
            if renderer.Config.Layout == "bottom"
                curveRegion = [0.075, 0.10, 0.87, 0.72*fraction];
                legendHeight = max(0.025, 0.022*ceil(numel(renderer.Config.Curves)/3));
                bottom = curveRegion(2)+curveRegion(4)+legendHeight+0.10;
                imageRegion = [0.035, bottom, 0.85, max(0.18, 0.86-bottom)];
                scaleRegion = [0.915, bottom+0.025, 0.010, max(0.15, imageRegion(4)-0.05)];
            else
                curveWidth = 0.87*fraction;
                curveRegion = [0.97-curveWidth, 0.17, curveWidth, 0.63];
                imageRegion = [0.035, 0.10, curveRegion(1)-0.17, 0.755];
                scaleRegion = [curveRegion(1)-0.10, 0.19, 0.011, 0.61];
            end
        end

        function positions = imagePositions(renderer, count)
            region = renderer.regions();
            left = region(1);
            bottom = region(2);
            width = region(3);
            height = region(4);
            if count == 1
                positions = [left, bottom, width, height];
            elseif count == 2
                gap = 0.025;
                panelWidth = (width-gap)/2;
                positions = [left, bottom, panelWidth, height; ...
                    left+panelWidth+gap, bottom, panelWidth, height];
            else
                columnGap = 0.025;
                rowGap = 0.075;
                panelWidth = (width-columnGap)/2;
                panelHeight = (height-rowGap)/2;
                positions = [left, bottom+panelHeight+rowGap, panelWidth, panelHeight; ...
                    left+panelWidth+columnGap, bottom+panelHeight+rowGap, panelWidth, panelHeight; ...
                    left, bottom, panelWidth, panelHeight; ...
                    left+panelWidth+columnGap, bottom, panelWidth, panelHeight];
                positions = positions(1:count, :);
            end
        end
    end

    methods (Static, Access = private)
        function configuration = normalizeConfiguration(configuration)
            defaults = struct(ImageTitles="Current section", ...
                Curves=struct("Name", {}, "Times", {}, "Values", {}, "Color", {}, "Unit", {}), ...
                ExperimentPlan=table(zeros(0, 1), zeros(0, 1), strings(0, 1), ...
                    VariableNames=["Start_s", "End_s", "Label"]), ...
                DisplayLimit=15, Unit="%ΔPD", Title="fUS response", ...
                FrameSize=[800, 1280], ROIs={{}}, MaskVertices={{}}, ...
                ShowColorbar=true, Duration=0, Layout="bottom", CurveFraction=0.26, ...
                ShowROILabels=false);
            fields = fieldnames(defaults);
            for index = 1:numel(fields)
                if ~isfield(configuration, fields{index})
                    configuration.(fields{index}) = defaults.(fields{index});
                end
            end
            configuration.ImageTitles = string(configuration.ImageTitles(:));
            count = numel(configuration.ImageTitles);
            if count < 1 || count > 4
                error("fUS:ReportImageCount", "汇报画布支持同时显示1至4个截面。");
            end
            if numel(configuration.FrameSize) ~= 2 ...
                    || any(~isfinite(configuration.FrameSize)) ...
                    || any(configuration.FrameSize < [240, 480])
                error("fUS:ReportFrameSize", "汇报画布尺寸至少为240×480像素。");
            end
            configuration.FrameSize = 16*ceil(double(configuration.FrameSize(:)')/16);
            configuration.Layout = string(configuration.Layout);
            if ~isscalar(configuration.Layout) || ~ismember(configuration.Layout, ["bottom", "right"])
                error("fUS:ReportLayout", "汇报布局必须为bottom或right。");
            end
            if ~isscalar(configuration.CurveFraction) || ~isfinite(configuration.CurveFraction) ...
                    || configuration.CurveFraction < 0.18 || configuration.CurveFraction > 0.50
                error("fUS:ReportLayout", "曲线区域占比必须介于0.18和0.50之间。");
            end
            if ~isscalar(configuration.DisplayLimit) || ~isfinite(configuration.DisplayLimit) ...
                    || configuration.DisplayLimit <= 0
                error("fUS:ReportDisplayLimit", "颜色范围必须是有限正数。");
            end
            configuration.ExperimentPlan = fus.ExperimentPlan.normalize(configuration.ExperimentPlan);
            if ~isfield(configuration, "ColorMap")
                if any(strcmp("blueWhiteRed", methods("fus.FrameRenderer")))
                    configuration.ColorMap = fus.FrameRenderer.blueWhiteRed(256);
                else
                    configuration.ColorMap = fus.FrameRenderer.blueWhiteOrange(256);
                end
            end
            for index = 1:count
                if numel(configuration.ROIs) < index
                    configuration.ROIs{index} = struct([]);
                end
                if numel(configuration.MaskVertices) < index
                    configuration.MaskVertices{index} = [];
                end
            end
            colors = fus.ReportRenderer.defaultColors();
            duration = 0;
            for index = 1:numel(configuration.Curves)
                curve = configuration.Curves(index);
                if ~all(isfield(curve, ["Name", "Times", "Values"]))
                    error("fUS:ReportCurve", "曲线需要Name、Times和Values。");
                end
                times = double(curve.Times(:));
                values = double(curve.Values(:));
                if isempty(times) || numel(times) ~= numel(values) ...
                        || any(~isfinite(times)) || any(times < 0) || any(diff(times) <= 0)
                    error("fUS:ReportCurve", "曲线时间必须递增、非负，且与数值长度一致。");
                end
                configuration.Curves(index).Name = string(curve.Name);
                configuration.Curves(index).Times = times;
                configuration.Curves(index).Values = values;
                if ~isfield(curve, "Color") || isempty(curve.Color)
                    color = colors(1+mod(index-1, size(colors, 1)), :);
                else
                    color = double(curve.Color(:)');
                end
                if numel(color) ~= 3 || any(~isfinite(color)) || any(color < 0 | color > 1)
                    error("fUS:ReportCurveColor", "曲线颜色必须为0至1之间的RGB三元组。");
                end
                configuration.Curves(index).Color = color;
                duration = max(duration, times(end));
            end
            if ~isscalar(configuration.Duration) || ~isfinite(configuration.Duration) ...
                    || configuration.Duration < 0
                error("fUS:ReportDuration", "汇报时间范围必须为有限非负数。");
            end
            if configuration.Duration == 0
                if duration == 0
                    duration = max([1; configuration.ExperimentPlan.End_s]);
                end
                configuration.Duration = max(1, duration);
            end
        end

        function colors = defaultColors()
            colors = [0.35, 0.77, 1.00; 1.00, 0.61, 0.31; ...
                0.44, 0.88, 0.64; 0.83, 0.61, 1.00; ...
                1.00, 0.45, 0.56; 0.91, 0.83, 0.36; ...
                0.44, 0.89, 0.89; 0.86, 0.86, 0.90];
        end

        function result = isStimulus(label)
            result = any(contains(lower(string(label)), ["刺激", "夹捏", "触摸", "stim"]));
        end

        function fontName = chooseFont()
            fontName = "Arial";
            try
                available = string(listfonts);
                preferred = ["Arial Unicode MS", "PingFang SC", "Microsoft YaHei", ...
                    "Noto Sans CJK SC", "Arial"];
                for name = preferred
                    if any(available == name)
                        fontName = name;
                        return
                    end
                end
            catch
                % 无桌面字体列表时使用MATLAB的标准字体。
            end
        end
    end
end
