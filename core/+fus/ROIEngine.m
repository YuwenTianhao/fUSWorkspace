classdef ROIEngine
    %ROIENGINE Convert polygon coordinates on the displayed image to pixels.

    methods (Static)
        function mask = polygonMask(position, imageSize, canvasSize)
            if size(position, 2) ~= 2 || size(position, 1) < 3 ...
                    || any(~isfinite(position(:)))
                error("fUS:InvalidPolygon", "ROI需要至少三个有效顶点。");
            end
            if numel(imageSize) ~= 2 || any(imageSize < 1) ...
                    || numel(canvasSize) ~= 2 || any(canvasSize <= 0)
                error("fUS:InvalidROIGeometry", "图像或画布尺寸无效。");
            end
            xCenters = linspace(0, canvasSize(1), imageSize(2));
            yCenters = linspace(0, canvasSize(2), imageSize(1));
            [xGrid, yGrid] = meshgrid(xCenters, yCenters);
            [inside, onBoundary] = inpolygon( ...
                xGrid, yGrid, position(:, 1), position(:, 2));
            mask = inside | onBoundary;
        end
    end
end
