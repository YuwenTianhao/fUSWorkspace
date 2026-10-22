classdef FrameRenderer
    %FRAMERENDERER 把原图或 CBV 数值转换成显示/视频用 RGB 图像。
    %
    % 此类不读取文件、不计算 CBV，只负责视觉表达。

    methods (Static)
        function shown = colorizeOriginal(frame, palette)
            palette = string(palette);
            if palette == "原图"
                shown = frame;
                return
            end
            gray = rgb2gray(frame);
            normalized = double(gray)/255.0;
            colorMap = feval(char(palette), 256);
            indices = min(256, max(1, floor(normalized*255) + 1));
            shown = im2uint8(ind2rgb(indices, colorMap));
        end

        function background = baselineBackground(baselineGray, showBackground)
            if showBackground
                anatomy = im2uint8(mat2gray(baselineGray));
                background = repmat(anatomy, 1, 1, 3);
            else
                background = zeros([size(baselineGray), 3], "uint8");
            end
        end

        function mask = visibleMask(map, analysisMask, displayParameters)
            mask = isfinite(map) & abs(map) >= displayParameters.LowThreshold ...
                & abs(map) > eps;
            if isfield(displayParameters, "ValidSignalMask") ...
                    && isequal(size(displayParameters.ValidSignalMask), size(map))
                mask = mask & logical(displayParameters.ValidSignalMask);
            end
            if isfield(displayParameters, "ApplyUserMask") && displayParameters.ApplyUserMask
                % 用户手绘区域只控制叠加显示，绝不改变定量 ROI 或 CBV 数值。
                if displayParameters.BrainMask && isfield(displayParameters, "UserMask") ...
                        && ~isempty(displayParameters.UserMask)
                    if ~isequal(size(displayParameters.UserMask), size(map))
                        error("fUS:DisplayMaskSizeMismatch", "手绘显示掩膜与图像尺寸不一致。");
                    end
                    mask = mask & logical(displayParameters.UserMask);
                end
            elseif displayParameters.BrainMask
                % 兼容旧版脚本调用；App 的新界面使用明确的手绘显示区域。
                mask = mask & analysisMask;
            end
        end

        function frame = renderCBV(map, baselineGray, analysisMask, displayParameters)
            background = fus.FrameRenderer.baselineBackground( ...
                baselineGray, displayParameters.ShowBackground);
            limit = max(displayParameters.HighThreshold, eps);
            normalized = min(1, max(0, (map + limit)/(2*limit)));
            normalized(~isfinite(normalized)) = 0.5;
            normalized(~isfinite(normalized)) = 0.5;
            colorIndices = min(256, max(1, floor(normalized*255) + 1));
            activity = im2uint8(ind2rgb( ...
                colorIndices, fus.FrameRenderer.blueWhiteRed(256)));
            mask = fus.FrameRenderer.visibleMask( ...
                map, analysisMask, displayParameters);
            alpha = displayParameters.Transparency*double(mask);
            alpha = repmat(alpha, 1, 1, 3);
            frame = im2uint8((1 - alpha).*im2double(background) ...
                + alpha.*im2double(activity));
        end

        function frame = drawTimestamp(frame, label)
            try
                [fontName, supportsChinese] = fus.FrameRenderer.timestampFont();
                if ~supportsChinese
                    label = extractBefore(string(label) + " | ", " | ");
                end
                frame = insertText(frame, [12, 12], label, ...
                    Font=fontName, ...
                    FontSize=max(14, round(size(frame, 2)/45)), ...
                    FontColor="white", TextBoxColor="black", BoxOpacity=0.65);
            catch
                % 字体或 insertText 不可用时保留原画面，视频仍可导出。
            end
        end

        function geometry = videoGeometry(ratio)
            % MPEG-4/H.264 的不同解码器对行步长有不同要求。仅保证偶数
            % 宽高仍可能让 434x720 这类视频在外部播放器中逐行错位。
            % 有效画面保持用户指定比例，编码画布再补黑边到16像素边界。
            ratio = max(eps, double(ratio));
            contentHeight = 720;
            contentWidth = round(contentHeight*ratio);
            if contentWidth > 1920
                contentWidth = 1920;
                contentHeight = round(contentWidth/ratio);
            end
            contentHeight = max(1, contentHeight);
            contentWidth = max(1, contentWidth);

            alignment = 16;
            canvasHeight = alignment*ceil(contentHeight/alignment);
            canvasWidth = alignment*ceil(contentWidth/alignment);
            geometry = struct( ...
                ContentHeight=contentHeight, ...
                ContentWidth=contentWidth, ...
                CanvasHeight=canvasHeight, ...
                CanvasWidth=canvasWidth, ...
                Alignment=alignment);
        end

        function canvas = fitToVideoCanvas(frame, geometry)
            resized = imresize(frame, ...
                [geometry.ContentHeight, geometry.ContentWidth]);
            canvas = zeros(geometry.CanvasHeight, geometry.CanvasWidth, ...
                size(resized, 3), "like", resized);
            top = floor((geometry.CanvasHeight - geometry.ContentHeight)/2) + 1;
            left = floor((geometry.CanvasWidth - geometry.ContentWidth)/2) + 1;
            rows = top:(top + geometry.ContentHeight - 1);
            columns = left:(left + geometry.ContentWidth - 1);
            canvas(rows, columns, :) = resized;
        end

        function [height, width] = videoFrameSize(ratio)
            % 保留旧接口；返回的是编码安全画布大小。
            geometry = fus.FrameRenderer.videoGeometry(ratio);
            height = geometry.CanvasHeight;
            width = geometry.CanvasWidth;
        end

        function colorMap = blueWhiteOrange(colorCount)
            negative = [53, 104, 171]/255.0;
            neutral = [0.94, 0.94, 0.94];
            positive = [230, 126, 34]/255.0;
            halfCount = floor(colorCount/2);
            negativeHalf = [ ...
                linspace(negative(1), neutral(1), halfCount)', ...
                linspace(negative(2), neutral(2), halfCount)', ...
                linspace(negative(3), neutral(3), halfCount)'];
            positiveCount = colorCount - halfCount;
            positiveHalf = [ ...
                linspace(neutral(1), positive(1), positiveCount)', ...
                linspace(neutral(2), positive(2), positiveCount)', ...
                linspace(neutral(3), positive(3), positiveCount)'];
            colorMap = [negativeHalf; positiveHalf];
        end

        function colorMap = blueWhiteRed(colorCount)
            % 对称发散色表：蓝色为负变化，红色为正变化，零附近为中性。
            anchors = [33, 102, 172; 247, 247, 247; 178, 24, 43]/255;
            colorMap = interp1([0, 0.5, 1], anchors, linspace(0, 1, colorCount), "linear");
        end
    end

    methods (Static, Access = private)
        function [fontName, supportsChinese] = timestampFont()
            persistent cachedFont cachedSupportsChinese
            if isempty(cachedFont)
                cachedFont = "Roboto-Regular";
                cachedSupportsChinese = false;
                try
                    availableFonts = string(listTrueTypeFonts);
                    preferredFonts = ["Arial Unicode", "Microsoft YaHei", ...
                        "Noto Sans CJK SC", "SimHei", "NISC18030"];
                    for index = 1:numel(preferredFonts)
                        match = find(strcmpi( ...
                            availableFonts, preferredFonts(index)), 1);
                        if ~isempty(match)
                            cachedFont = availableFonts(match);
                            cachedSupportsChinese = true;
                            break
                        end
                    end
                catch
                    % Roboto 是 insertText 的内置后备字体。
                end
            end
            fontName = cachedFont;
            supportsChinese = cachedSupportsChinese;
        end
    end
end
