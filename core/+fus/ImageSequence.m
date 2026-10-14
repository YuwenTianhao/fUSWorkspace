classdef ImageSequence < handle
    %IMAGESEQUENCE 读取并缓存一个 fUS SVD 图像序列。
    %
    % 这个类只关心“图像在哪里、顺序是什么、怎样高效读取”，不包含
    % CBV 算法或界面逻辑。文件名中若包含 frames_起始_结束，会按原始
    % 帧号排序；否则按文件名排序。

    properties (SetAccess = private)
        Folder string = ""
        Files string = strings(0, 1)
        FrameStarts double = zeros(0, 1)
        FrameEnds double = zeros(0, 1)
        SourceType string = "image"
    end

    properties (Access = private)
        Cache
        CacheOrder string = strings(0, 1)
        MaxCacheFrames double = 24
    end

    methods
        function sequence = ImageSequence(folder, options)
            arguments
                folder {mustBeTextScalar}
                options.MaxCacheFrames (1, 1) double {mustBeInteger, mustBePositive} = 24
            end

            folder = string(folder);
            if isfolder(fullfile(folder, "SVD"))
                folder = fullfile(folder, "SVD");
            end
            if ~isfolder(folder)
                error("fUS:DataFolderNotFound", "数据文件夹不存在：%s", folder);
            end

            [files, starts, ends] = fus.ImageSequence.listImageFiles(folder);
            if isempty(files)
                error("fUS:NoImages", "文件夹中没有找到 BMP 或 PNG 图像：%s", folder);
            end

            sequence.Folder = folder;
            sequence.Files = files;
            sequence.FrameStarts = starts;
            sequence.FrameEnds = ends;
            sequence.MaxCacheFrames = options.MaxCacheFrames;
            sequence.clearCache();
        end

        function count = frameCount(sequence)
            count = numel(sequence.Files);
        end

        function frame = readFrame(sequence, index)
            sequence.validateIndex(index);
            key = char(sequence.Files(index));
            if isKey(sequence.Cache, key)
                frame = sequence.Cache(key);
                sequence.CacheOrder(sequence.CacheOrder == string(key)) = [];
                sequence.CacheOrder(end + 1) = string(key);
                return
            end

            [frame, colorMap] = imread(key);
            if ~isempty(colorMap)
                frame = im2uint8(ind2rgb(frame, colorMap));
            end
            if size(frame, 3) == 1
                frame = repmat(frame, 1, 1, 3);
            end
            frame = im2uint8(frame);

            sequence.Cache(key) = frame;
            sequence.CacheOrder(end + 1) = string(key);
            sequence.trimCache();
        end

        function gray = readGray(sequence, index)
            frame = sequence.readFrame(index);
            % SVD 导出图通常是三个通道完全相同的灰度图。沿用原 App 的
            % 定义，取第一通道，避免 rgb2gray 引入额外加权变化。
            gray = double(frame(:, :, 1));
        end

        function average = meanGray(sequence, indices)
            indices = sequence.validateIndices(indices);
            total = zeros(size(sequence.readGray(indices(1))), "double");
            for index = indices
                total = total + sequence.readGray(index);
            end
            average = total/numel(indices);
        end

        function average = meanSignal(sequence, indices, conversionParameters)
            indices = sequence.validateIndices(indices);
            first = fus.CBVEngine.storedGrayToSignal( ...
                sequence.readGray(indices(1)), conversionParameters);
            total = zeros(size(first), "double");
            for index = indices
                gray = sequence.readGray(index);
                total = total + fus.CBVEngine.storedGrayToSignal( ...
                    gray, conversionParameters);
            end
            average = total/numel(indices);
        end

        function clearCache(sequence)
            sequence.Cache = containers.Map(KeyType="char", ValueType="any");
            sequence.CacheOrder = strings(0, 1);
        end
    end

    methods (Access = private)
        function validateIndex(sequence, index)
            if ~isscalar(index) || index < 1 || index > sequence.frameCount() ...
                    || index ~= round(index)
                error("fUS:FrameOutsideSequence", ...
                    "图像序号必须是 1-%d 之间的整数。", sequence.frameCount());
            end
        end

        function indices = validateIndices(sequence, indices)
            indices = double(indices(:)');
            if isempty(indices) || any(indices < 1) ...
                    || any(indices > sequence.frameCount()) ...
                    || any(indices ~= round(indices))
                error("fUS:FramesOutsideSequence", ...
                    "图像序号超出 1-%d。", sequence.frameCount());
            end
        end

        function trimCache(sequence)
            while numel(sequence.CacheOrder) > sequence.MaxCacheFrames
                oldKey = char(sequence.CacheOrder(1));
                sequence.CacheOrder(1) = [];
                if isKey(sequence.Cache, oldKey)
                    remove(sequence.Cache, oldKey);
                end
            end
        end
    end

    methods (Static, Access = private)
        function [files, starts, ends] = listImageFiles(folder)
            entries = [dir(fullfile(folder, "*.bmp")); ...
                dir(fullfile(folder, "*.BMP")); ...
                dir(fullfile(folder, "*.png")); ...
                dir(fullfile(folder, "*.PNG"))];
            names = string({entries.name})';
            valid = ~startsWith(names, "._") & ~startsWith(names, ".");
            entries = entries(valid);
            names = names(valid);
            paths = string(fullfile({entries.folder}, {entries.name}))';
            [paths, uniqueIndices] = unique(paths, "stable");
            names = names(uniqueIndices);

            starts = nan(numel(paths), 1);
            ends = nan(numel(paths), 1);
            for index = 1:numel(paths)
                token = regexp(names(index), "frames_(\d+)_(\d+)", ...
                    "tokens", "once");
                if ~isempty(token)
                    starts(index) = str2double(token{1});
                    ends(index) = str2double(token{2});
                else
                    starts(index) = index;
                    ends(index) = index;
                end
            end

            sortTable = table(starts, lower(names), (1:numel(paths))', ...
                VariableNames=["Start", "Name", "OriginalIndex"]);
            sortTable = sortrows(sortTable, ["Start", "Name"]);
            order = sortTable.OriginalIndex;
            files = paths(order);
            starts = starts(order);
            ends = ends(order);
        end
    end

    methods (Static)
        function available = isAvailable(folder)
            folder = string(folder);
            if isfolder(fullfile(folder, "SVD"))
                folder = fullfile(folder, "SVD");
            end
            if ~isfolder(folder)
                available = false;
                return
            end
            patterns = ["*.bmp", "*.BMP", "*.png", "*.PNG"];
            available = false;
            for pattern = patterns
                if ~isempty(dir(fullfile(folder, pattern)))
                    available = true;
                    return
                end
            end
        end
    end
end
