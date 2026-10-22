classdef fUSWorkspaceExportPreview < handle
    %FUSWORKSPACEEXPORTPREVIEW 用真正的导出渲染器预览，不写入视频或实验数据。
    % 图像提供者只读取指定帧；所有布局选择由getSettings返回给导出工作流。
    properties (Access = private)
        Figure
        PreviewImage
        StyleControl
        LayoutControl
        FractionControl
        SizeControl
        LabelsControl
        FrameControl
        Status
        ConfirmButton
        Specification struct
        Renderer = []
        RenderSettings struct = struct()
        Confirmed logical = false
        Ready logical = false
    end

    methods
        function preview = fUSWorkspaceExportPreview(specification)
            preview.Specification = specification;
            try
                preview.buildUI();
                preview.refresh();
            catch errorInfo
                delete(preview);
                rethrow(errorInfo);
            end
        end

        function settings = run(preview)
            uiwait(preview.Figure);
            settings = struct([]);
            if preview.Confirmed && isgraphics(preview.Figure)
                settings = preview.getSettings();
            end
        end

        function figureHandle = getFigure(preview)
            figureHandle = preview.Figure;
        end

        function settings = getSettings(preview)
            settings = struct(Style=string(preview.StyleControl.Value), ...
                Layout=string(preview.LayoutControl.Value), ...
                CurveFraction=preview.FractionControl.Value/100, ...
                FrameSize=preview.SizeControl.Value, ...
                ShowROILabels=preview.LabelsControl.Value);
        end

        function refresh(preview)
            settings = preview.getSettings();
            isReport = settings.Style == "presentation";
            preview.LayoutControl.Enable = matlab.lang.OnOffSwitchState(isReport);
            preview.FractionControl.Enable = matlab.lang.OnOffSwitchState(isReport);
            preview.SizeControl.Enable = matlab.lang.OnOffSwitchState(isReport);
            preview.LabelsControl.Enable = matlab.lang.OnOffSwitchState(isReport);
            index = max(1, min(preview.Specification.FrameCount, round(preview.FrameControl.Value)));
            seconds = index/preview.Specification.ActualFPS;
            if isReport
                if isempty(preview.Renderer) || ~isequaln(settings, preview.RenderSettings)
                    preview.deleteRenderer();
                    configuration = preview.Specification.ReportConfiguration;
                    configuration.Layout = settings.Layout;
                    configuration.CurveFraction = settings.CurveFraction;
                    configuration.FrameSize = settings.FrameSize;
                    configuration.ShowROILabels = settings.ShowROILabels;
                    preview.Renderer = fus.ReportRenderer(configuration);
                    preview.RenderSettings = settings;
                end
                images = preview.Specification.ImageProvider(index);
                frame = preview.Renderer.render(images, seconds);
            else
                frame = preview.Specification.PureImageProvider(index);
            end
            preview.PreviewImage.ImageSource = frame;
            preview.Status.Text = sprintf("第 %d / %d 帧 · 实验时间 %.2f s · 导出尺寸 %d × %d · 预览等比缩放，不拉伸", ...
                index, preview.Specification.FrameCount, seconds, size(frame, 2), size(frame, 1));
            preview.Ready = true;
            preview.ConfirmButton.Enable = "on";
        end

        function delete(preview)
            preview.deleteRenderer();
            if ~isempty(preview.Figure) && isgraphics(preview.Figure)
                delete(preview.Figure);
            end
        end
    end

    methods (Access = private)
        function buildUI(preview)
            settings = preview.Specification.Settings;
            preview.Figure = uifigure(Name="视频导出预览 · 确认后才生成MP4", ...
                Position=[60, 50, 1280, 850], Color=[0.95, 0.96, 0.97], ...
                Tag="fUSExportPreview", CloseRequestFcn=@(~, ~)preview.cancel());
            if isfield(preview.Specification, "Modal") && preview.Specification.Modal
                preview.Figure.WindowStyle = "modal";
            end
            grid = uigridlayout(preview.Figure, [4, 1], ...
                RowHeight={66, "1x", 48, 34}, Padding=[10, 8, 10, 8]);
            controls = uigridlayout(grid, [2, 5], ...
                RowHeight={20, 28}, ColumnWidth={180, 180, 160, 180, "1x"}, ...
                Padding=[0, 0, 0, 0], RowSpacing=4);
            labels = ["导出内容", "曲线位置", "曲线区域占比 (%)", "报告分辨率", "ROI标注"];
            for index = 1:5
                label = uilabel(controls, Text=labels(index));
                label.Layout.Row = 1;
                label.Layout.Column = index;
            end
            preview.StyleControl = uidropdown(controls, Items=["图像＋曲线", "纯图像"], ...
                ItemsData=["presentation", "image"], Value=settings.Style, ...
                Tag="ExportPreviewStyle", ValueChangedFcn=@(~, ~)preview.updatePreview());
            preview.LayoutControl = uidropdown(controls, Items=["曲线在下方（横向）", "曲线在右侧"], ...
                ItemsData=["bottom", "right"], Value=settings.Layout, ...
                Tag="ExportPreviewLayout", ValueChangedFcn=@(~, ~)preview.updatePreview());
            preview.FractionControl = uieditfield(controls, "numeric", Limits=[18, 50], ...
                Value=100*settings.CurveFraction, RoundFractionalValues="on", ...
                Tag="ExportPreviewFraction", ValueChangedFcn=@(~, ~)preview.updatePreview());
            sizes = {[800, 1280], [1088, 1920], [1200, 1600]};
            names = ["1280 × 800", "1920 × 1088", "1600 × 1200"];
            if ~any(cellfun(@(item)isequal(item, settings.FrameSize), sizes))
                sizes{end+1} = settings.FrameSize;
                names(end+1) = sprintf("%d × %d", settings.FrameSize(2), settings.FrameSize(1));
            end
            preview.SizeControl = uidropdown(controls, Items=names, ItemsData=sizes, ...
                Value=settings.FrameSize, Tag="ExportPreviewSize", ...
                ValueChangedFcn=@(~, ~)preview.updatePreview());
            preview.LabelsControl = uicheckbox(controls, Text="显示名称（默认仅轮廓）", ...
                Value=settings.ShowROILabels, Tag="ExportPreviewLabels", ...
                ValueChangedFcn=@(~, ~)preview.updatePreview());
            widgets = {preview.StyleControl, preview.LayoutControl, preview.FractionControl, ...
                preview.SizeControl, preview.LabelsControl};
            for index = 1:5
                widgets{index}.Layout.Row = 2;
                widgets{index}.Layout.Column = index;
            end
            canvas = uipanel(grid, BackgroundColor=[0.025, 0.03, 0.04], BorderType="none");
            canvas.Layout.Row = 2;
            canvasGrid = uigridlayout(canvas, [1, 1], Padding=[0, 0, 0, 0], ...
                BackgroundColor=[0.025, 0.03, 0.04]);
            preview.PreviewImage = uiimage(canvasGrid, ScaleMethod="fit", Tag="ExportPreviewImage");
            timeline = uigridlayout(grid, [1, 2], ColumnWidth={86, "1x"}, ...
                Padding=[2, 5, 12, 0]);
            timeline.Layout.Row = 3;
            uilabel(timeline, Text="拖动预览帧");
            preview.FrameControl = uislider(timeline, ...
                Limits=[1, max(2, preview.Specification.FrameCount)], ...
                Value=preview.Specification.InitialIndex, ...
                Enable=matlab.lang.OnOffSwitchState(preview.Specification.FrameCount > 1), ...
                MajorTicks=[], MinorTicks=[], Tag="ExportPreviewFrame", ...
                ValueChangedFcn=@(~, ~)preview.updatePreview());
            footer = uigridlayout(grid, [1, 3], ColumnWidth={"1x", 80, 150}, ...
                Padding=[0, 0, 0, 0]);
            footer.Layout.Row = 4;
            preview.Status = uilabel(footer, Text="正在生成预览…", FontSize=10);
            uibutton(footer, Text="取消", ButtonPushedFcn=@(~, ~)preview.cancel());
            preview.ConfirmButton = uibutton(footer, Text="确认布局并选择保存…", Enable="off", ...
                ButtonPushedFcn=@(~, ~)preview.confirm());
        end

        function updatePreview(preview)
            preview.Ready = false;
            preview.ConfirmButton.Enable = "off";
            try
                preview.refresh();
            catch errorInfo
                preview.Status.Text = "预览失败：" + string(errorInfo.message);
            end
        end

        function confirm(preview)
            if preview.Ready
                preview.Confirmed = true;
                uiresume(preview.Figure);
            end
        end

        function cancel(preview)
            preview.Confirmed = false;
            uiresume(preview.Figure);
            preview.Figure.Visible = "off";
        end

        function deleteRenderer(preview)
            if ~isempty(preview.Renderer) && isvalid(preview.Renderer)
                delete(preview.Renderer);
            end
            preview.Renderer = [];
        end
    end
end
