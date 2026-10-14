classdef CBVEngine
    %CBVENGINE 与界面无关的 baseline 和相对 CBV 计算。
    %
    % 新增或替换 CBV 算法时，优先在这个类中实现。App 只负责从控件
    % 收集 parameters，并把 ImageSequence 交给这里。

    methods (Static)
        function parameters = defaultParameters()
            parameters = struct( ...
                SpatialAveragePixels=5, ...
                TemporalAverageFrames=5, ...
                ConversionMode="unknown", ...
                DynamicRangeDb=60, ...
                Log10PerGray=0.01, ...
                MinimumBaselineGray=35);
        end

        function baseline = computeBaseline(sequence, secondsRange, actualFPS, parameters)
            parameters = fus.CBVEngine.validateParameters(parameters);
            fus.CBVEngine.validateSequenceMode(sequence, parameters);
            indices = fus.CBVEngine.secondsToIndices( ...
                secondsRange, actualFPS, sequence.frameCount());

            baselineGray = fus.CBVEngine.spatialAverage( ...
                sequence.meanGray(indices), parameters.SpatialAveragePixels);
            if fus.CBVEngine.isCalibratedMode(parameters)
                baselineSignal = fus.CBVEngine.spatialAverage( ...
                    sequence.meanSignal(indices, parameters), ...
                    parameters.SpatialAveragePixels);
            else
                baselineSignal = baselineGray;
            end

            baseline = struct( ...
                Gray=baselineGray, ...
                Signal=baselineSignal, ...
                AnalysisMask=fus.CBVEngine.createAnalysisMask( ...
                    baselineGray, parameters.MinimumBaselineGray), ...
                Indices=indices, ...
                Parameters=parameters);
        end

        function [map, indices] = calculateMap( ...
                sequence, baseline, centerIndex, parameters)
            parameters = fus.CBVEngine.validateParameters(parameters);
            fus.CBVEngine.validateSequenceMode(sequence, parameters);
            indices = fus.CBVEngine.temporalWindow( ...
                centerIndex, parameters.TemporalAverageFrames, sequence.frameCount());

            if fus.CBVEngine.isCalibratedMode(parameters)
                currentSignal = fus.CBVEngine.spatialAverage( ...
                    sequence.meanSignal(indices, parameters), ...
                    parameters.SpatialAveragePixels);
                map = 100.0*(currentSignal - baseline.Signal) ...
                    ./max(baseline.Signal, eps);
            else
                currentGray = fus.CBVEngine.spatialAverage( ...
                    sequence.meanGray(indices), parameters.SpatialAveragePixels);
                map = currentGray - baseline.Gray;
            end
        end

        function [times, curves] = calculateROICurves( ...
                sequence, baseline, masks, parameters, actualFPS, progressFcn)
            % 空间与时间平均均为线性运算。先把空间滤波折算成每个
            % ROI 的像素权重，每帧只读取一次并对ROI支持域求加权和。
            if nargin < 6
                progressFcn = [];
            end
            parameters = fus.CBVEngine.validateParameters(parameters);
            fus.CBVEngine.validateSequenceMode(sequence, parameters);
            if ~iscell(masks) || isempty(masks)
                error("fUS:NoROI", "请先添加至少一个ROI。");
            end
            if ~isscalar(actualFPS) || ~isfinite(actualFPS) || actualFPS <= 0
                error("fUS:InvalidFPS", "实际帧率必须为正数。");
            end
            imageSize = size(baseline.Gray);
            pixels = cell(1, numel(masks));
            for roiIndex = 1:numel(masks)
                mask = masks{roiIndex};
                if ~islogical(mask) || ~isequal(size(mask), imageSize) ...
                        || ~any(mask(:))
                    error("fUS:InvalidROI", ...
                        "ROI %d为空或与当前数据尺寸不匹配。", roiIndex);
                end
                pixels{roiIndex} = find(mask);
            end
            frameCount = sequence.frameCount();
            times = (1:frameCount)'/actualFPS;
            roiCount = numel(masks);
            frameMeans = zeros(frameCount, roiCount);
            calibrated = fus.CBVEngine.isCalibratedMode(parameters);
            if calibrated
                denominator = max(baseline.Signal, eps);
                reference = 100*baseline.Signal./denominator;
            else
                reference = baseline.Gray;
            end
            referenceMeans = zeros(1, roiCount);
            supports = cell(1, roiCount);
            weights = cell(1, roiCount);
            for roiIndex = 1:roiCount
                referenceMeans(roiIndex) = mean(reference(pixels{roiIndex}));
                coefficients = zeros(imageSize);
                if calibrated
                    coefficients(pixels{roiIndex}) = ...
                        100./denominator(pixels{roiIndex})/numel(pixels{roiIndex});
                else
                    coefficients(pixels{roiIndex}) = 1/numel(pixels{roiIndex});
                end
                [supports{roiIndex}, weights{roiIndex}] = ...
                    fus.CBVEngine.spatialAverageWeights( ...
                        coefficients, parameters.SpatialAveragePixels);
            end
            for frameIndex = 1:frameCount
                raw = sequence.readGray(frameIndex);
                if calibrated
                    raw = fus.CBVEngine.storedGrayToSignal(raw, parameters);
                end
                for roiIndex = 1:roiCount
                    frameMeans(frameIndex, roiIndex) = sum( ...
                        raw(supports{roiIndex}).*weights{roiIndex});
                end
                if ~isempty(progressFcn) && ~progressFcn(frameIndex, frameCount)
                    error("fUS:ROICurveCancelled", "ROI曲线计算已取消。");
                end
            end
            prefix = [zeros(1, roiCount); cumsum(frameMeans, 1)];
            curves = zeros(frameCount, roiCount);
            for frameIndex = 1:frameCount
                indices = fus.CBVEngine.temporalWindow( ...
                    frameIndex, parameters.TemporalAverageFrames, frameCount);
                curves(frameIndex, :) = ...
                    (prefix(indices(end)+1, :) - prefix(indices(1), :)) ...
                    /numel(indices) - referenceMeans;
            end
        end

        function indices = secondsToIndices(secondsRange, actualFPS, frameCount)
            startIndex = floor(secondsRange(1)*actualFPS) + 1;
            endIndex = floor(secondsRange(2)*actualFPS);
            if startIndex < 1 || endIndex > frameCount || startIndex > endIndex
                error("fUS:BaselineOutsideData", ...
                    "baseline %.3f-%.3f s 对应图像 %d-%d，超出1-%d。", ...
                    secondsRange(1), secondsRange(2), ...
                    startIndex, endIndex, frameCount);
            end
            indices = startIndex:endIndex;
        end

        function indices = temporalWindow(centerIndex, count, frameCount)
            count = round(count);
            before = floor((count - 1)/2);
            startIndex = centerIndex - before;
            endIndex = startIndex + count - 1;
            if startIndex < 1
                endIndex = min(frameCount, endIndex + 1 - startIndex);
                startIndex = 1;
            end
            if endIndex > frameCount
                startIndex = max(1, startIndex - (endIndex - frameCount));
                endIndex = frameCount;
            end
            indices = startIndex:endIndex;
        end

        function signal = storedGrayToSignal(gray, parameters)
            parameters = fus.CBVEngine.validateParameters(parameters);
            switch string(parameters.ConversionMode)
                case "dB8bit"
                    dbPerGray = parameters.DynamicRangeDb/255.0;
                    signal = 10.^(gray*dbPerGray/10.0);
                case "log10Scaled"
                    signal = 10.^(gray*parameters.Log10PerGray);
                case "linear"
                    signal = gray;
                case "unknown"
                    error("fUS:UnknownScale", ...
                        "log/dB映射未知，不能计算线性CBV百分比。");
                otherwise
                    error("fUS:InvalidMode", "不支持的转换模式：%s", ...
                        parameters.ConversionMode);
            end
        end

        function filtered = spatialAverage(data, filterSize)
            filterSize = round(filterSize);
            if mod(filterSize, 2) == 0
                filterSize = filterSize + 1;
            end
            filtered = imboxfilt(data, filterSize, Padding="replicate");
        end

        function mask = createAnalysisMask(baselineGray, minimumBaselineGray)
            [height, width] = size(baselineGray);
            centralField = false(height, width);
            rows = max(1, floor(0.08*height)):min(height, ceil(0.92*height));
            columns = max(1, floor(0.125*width)):min(width, ceil(0.875*width));
            centralField(rows, columns) = true;
            mask = centralField & baselineGray >= minimumBaselineGray;
        end

        function calibrated = isCalibratedMode(parameters)
            calibrated = string(parameters.ConversionMode) ~= "unknown";
        end

        function unit = unitLabel(parameters)
            switch string(parameters.ConversionMode)
                case "unknown"
                    unit = "Δlog灰度";
                case "dB8bit"
                    unit = sprintf("%%ΔPD（8-bit覆盖 %.3g dB）", ...
                        parameters.DynamicRangeDb);
                case "log10Scaled"
                    unit = sprintf("%%ΔPD（%.4g log10单位/灰度）", ...
                        parameters.Log10PerGray);
                case "linear"
                    unit = "%ΔPD（线性输入）";
                otherwise
                    unit = "未知单位";
            end
        end
    end

    methods (Static, Access = private)
        function [support, weights] = spatialAverageWeights(coefficients, filterSize)
            % imboxfilt(...,Padding="replicate") 的转置作用于 ROI 权重。
            filterSize = round(filterSize);
            if mod(filterSize, 2) == 0
                filterSize = filterSize + 1;
            end
            if filterSize == 1
                weightMap = coefficients;
            else
                half = (filterSize-1)/2;
                [height, width] = size(coefficients);
                expanded = conv2(coefficients, ...
                    ones(filterSize)/(filterSize^2), "full");
                folded = expanded(half+1:half+height, :);
                folded(1, :) = folded(1, :) + sum(expanded(1:half, :), 1);
                folded(end, :) = folded(end, :) + ...
                    sum(expanded(half+height+1:end, :), 1);
                weightMap = folded(:, half+1:half+width);
                weightMap(:, 1) = weightMap(:, 1) + ...
                    sum(folded(:, 1:half), 2);
                weightMap(:, end) = weightMap(:, end) + ...
                    sum(folded(:, half+width+1:end), 2);
            end
            support = find(weightMap);
            weights = weightMap(support);
        end

        function validateSequenceMode(sequence, parameters)
            if isprop(sequence, "SourceType") ...
                    && string(sequence.SourceType) == "pdi" ...
                    && string(parameters.ConversionMode) ~= "linear"
                error("fUS:PDIRequiresLinearMode", ...
                    "PDI已是显示压缩前的数值，必须使用线性输入模式。");
            end
        end

        function parameters = validateParameters(parameters)
            required = ["SpatialAveragePixels", "TemporalAverageFrames", ...
                "ConversionMode", "DynamicRangeDb", "Log10PerGray", ...
                "MinimumBaselineGray"];
            missing = required(~isfield(parameters, required));
            if ~isempty(missing)
                error("fUS:MissingCBVParameter", ...
                    "CBV参数缺少字段：%s", strjoin(missing, ", "));
            end
            parameters.ConversionMode = string(parameters.ConversionMode);
            validModes = ["unknown", "dB8bit", "log10Scaled", "linear"];
            if ~any(parameters.ConversionMode == validModes)
                error("fUS:InvalidMode", "不支持的转换模式：%s", ...
                    parameters.ConversionMode);
            end
            if parameters.SpatialAveragePixels < 1 ...
                    || parameters.TemporalAverageFrames < 1
                error("fUS:InvalidAveraging", "空间和时间平均必须至少为1。");
            end
        end
    end
end
