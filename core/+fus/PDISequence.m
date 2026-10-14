classdef PDISequence < handle
    %PDISEQUENCE 读取并缓存 Marsonics raw Power Doppler 文件序列。
    % PDI 的 float32 payload 是显示 log 压缩前的数值；readFrame 仅为
    % 浏览重建灰度显示，readGray/meanSignal 保留线性 PDI 数值供计算。

    properties (SetAccess = private)
        Folder string = ""
        Files string = strings(0, 1)
        FrameStarts double = zeros(0, 1)
        FrameEnds double = zeros(0, 1)
        Headers struct = struct([])
        SourceType string = "pdi"
    end

    properties (Access = private)
        Cache
        CacheOrder string = strings(0, 1)
        MaxCacheFrames double = 24
    end

    methods
        function sequence = PDISequence(folder, options)
            arguments
                folder {mustBeTextScalar}
                options.MaxCacheFrames (1, 1) double ...
                    {mustBeInteger, mustBePositive} = 24
            end
            folder = fus.PDISequence.resolveFolder(folder);
            entries = dir(fullfile(folder, "*.pdi"));
            entries = entries(~[entries.isdir]);
            if isempty(entries)
                error("fUS:NoPDI", "文件夹中没有找到PDI文件：%s", folder);
            end

            headers = repmat(fus.PDISequence.emptyHeader(), numel(entries), 1);
            for index = 1:numel(entries)
                headers(index) = fus.PDISequence.readHeader( ...
                    fullfile(entries(index).folder, entries(index).name));
            end
            [~, order] = sort(double([headers.Sequence]));
            headers = headers(order);
            sequence.validateSequence(headers);

            sequence.Folder = folder;
            sequence.Headers = headers;
            sequence.Files = string({headers.FilePath})';
            sequence.FrameStarts = double([headers.FirstFrame])';
            sequence.FrameEnds = double([headers.LastFrame])';
            sequence.MaxCacheFrames = options.MaxCacheFrames;
            sequence.clearCache();
        end

        function count = frameCount(sequence)
            count = numel(sequence.Files);
        end

        function raw = readGray(sequence, index)
            sequence.validateIndex(index);
            key = char(sequence.Files(index));
            if isKey(sequence.Cache, key)
                raw = sequence.Cache(key);
                sequence.CacheOrder(sequence.CacheOrder == string(key)) = [];
                sequence.CacheOrder(end + 1) = string(key);
                return
            end
            header = sequence.Headers(index);
            fileId = fopen(header.FilePath, "rb", "ieee-le");
            if fileId < 0
                error("fUS:PDIOpenFailed", "无法打开PDI文件：%s", header.FilePath);
            end
            cleanup = onCleanup(@()fclose(fileId));
            if fseek(fileId, double(header.HeaderBytes), "bof") ~= 0
                error("fUS:PDISeekFailed", "无法定位PDI数据区：%s", header.FilePath);
            end
            raw = fread(fileId, [double(header.Height), double(header.Width)], ...
                "single=>double");
            if numel(raw) ~= double(header.PayloadFloatCount)
                error("fUS:PDITruncatedPayload", "PDI数据区不完整：%s", header.FilePath);
            end
            if any(~isfinite(raw), "all") || any(raw < 0, "all")
                error("fUS:PDIInvalidPayload", ...
                    "PDI数据包含非有限值或负值：%s", header.FilePath);
            end
            clear cleanup
            sequence.Cache(key) = raw;
            sequence.CacheOrder(end + 1) = string(key);
            sequence.trimCache();
        end

        function frame = readFrame(sequence, index)
            raw = sequence.readGray(index);
            header = sequence.Headers(index);
            safeRaw = max(raw, realmin("double"));
            displayDb = header.PdiDbMultiplier*log10( ...
                safeRaw/header.PdiReferenceLinear) + header.DisplayGainDb;
            normalized = (displayDb + header.DisplayDynamicRangeDb) ...
                /header.DisplayDynamicRangeDb;
            gray = im2uint8(min(1, max(0, normalized)));
            frame = repmat(gray, 1, 1, 3);
        end

        function average = meanGray(sequence, indices)
            average = sequence.meanRaw(indices);
        end

        function average = meanSignal(sequence, indices, conversionParameters)
            if string(conversionParameters.ConversionMode) ~= "linear"
                error("fUS:PDIRequiresLinearMode", ...
                    "PDI已是显示压缩前的数值，必须使用线性输入模式。");
            end
            average = sequence.meanRaw(indices);
        end

        function clearCache(sequence)
            sequence.Cache = containers.Map(KeyType="char", ValueType="any");
            sequence.CacheOrder = strings(0, 1);
        end
    end

    methods (Access = private)
        function average = meanRaw(sequence, indices)
            indices = sequence.validateIndices(indices);
            total = zeros(size(sequence.readGray(indices(1))), "double");
            for index = indices
                total = total + sequence.readGray(index);
            end
            average = total/numel(indices);
        end

        function validateIndex(sequence, index)
            if ~isscalar(index) || index < 1 || index > sequence.frameCount() ...
                    || index ~= round(index)
                error("fUS:FrameOutsideSequence", ...
                    "PDI序号必须是1-%d之间的整数。", sequence.frameCount());
            end
        end

        function indices = validateIndices(sequence, indices)
            indices = double(indices(:)');
            if isempty(indices) || any(indices < 1) ...
                    || any(indices > sequence.frameCount()) ...
                    || any(indices ~= round(indices))
                error("fUS:FramesOutsideSequence", ...
                    "PDI序号超出1-%d。", sequence.frameCount());
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

        function validateSequence(~, headers)
            sequences = double([headers.Sequence]);
            if numel(unique(sequences)) ~= numel(sequences)
                error("fUS:DuplicatePDISequence", "检测到重复的PDI sequence。");
            end
            if numel(sequences) > 1 && any(diff(sequences) ~= 1)
                error("fUS:PDISequenceGap", "PDI sequence存在缺号。");
            end
            reference = headers(1);
            for index = 1:numel(headers)
                current = headers(index);
                if current.Width ~= reference.Width ...
                        || current.Height ~= reference.Height ...
                        || current.Layout ~= 1
                    error("fUS:PDIGridMismatch", "PDI尺寸或布局不一致：%s", ...
                        current.FilePath);
                end
                if current.LastFrame < current.FirstFrame ...
                        || current.LastFrame-current.FirstFrame+1 ~= current.SourceFrames
                    error("fUS:PDIFrameRangeMismatch", ...
                        "PDI源帧范围与sourceFrames不一致：%s", current.FilePath);
                end
                if current.Version == 1 ...
                        && current.ValidFrames+current.RejectedFrames ...
                        ~= current.SourceFrames
                    error("fUS:PDIFrameCountMismatch", ...
                        "PDI有效帧数与剔除帧数不等于sourceFrames：%s", ...
                        current.FilePath);
                end
                if index > 1 && current.FirstFrame ~= headers(index-1).LastFrame+1
                    error("fUS:PDIFrameGap", "PDI源帧范围存在缺口或重叠：%s", ...
                        current.FilePath);
                end
            end
        end
    end

    methods (Static)
        function available = isAvailable(folder)
            try
                folder = fus.PDISequence.resolveFolder(folder);
                available = ~isempty(dir(fullfile(folder, "*.pdi")));
            catch
                available = false;
            end
        end
    end

    methods (Static, Access = private)
        function folder = resolveFolder(folder)
            folder = string(folder);
            if isfolder(fullfile(folder, "SVD"))
                folder = fullfile(folder, "SVD");
            end
            if ~isfolder(folder)
                error("fUS:DataFolderNotFound", "数据文件夹不存在：%s", folder);
            end
        end

        function header = readHeader(filePath)
            fileId = fopen(filePath, "rb", "ieee-le");
            if fileId < 0
                error("fUS:PDIOpenFailed", "无法打开PDI文件：%s", filePath);
            end
            cleanup = onCleanup(@()fclose(fileId));
            magic = char(fread(fileId, 8, "uint8=>char")');
            if ~strcmp(magic, "MRSPDI01")
                error("fUS:PDIBadMagic", "不是受支持的Marsonics PDI：%s", filePath);
            end
            header = fus.PDISequence.emptyHeader();
            header.FilePath = char(filePath);
            header.Version = fus.PDISequence.readOne(fileId, "uint32=>uint32", filePath);
            header.HeaderBytes = fus.PDISequence.readOne(fileId, "uint32=>uint32", filePath);
            header.Width = fus.PDISequence.readOne(fileId, "uint32=>uint32", filePath);
            header.Height = fus.PDISequence.readOne(fileId, "uint32=>uint32", filePath);
            header.Sequence = fus.PDISequence.readOne(fileId, "uint64=>uint64", filePath);
            header.FirstFrame = fus.PDISequence.readOne(fileId, "uint32=>uint32", filePath);
            header.LastFrame = fus.PDISequence.readOne(fileId, "uint32=>uint32", filePath);
            header.SourceFrames = fus.PDISequence.readOne(fileId, "uint32=>uint32", filePath);
            if header.Version == 1
                header.ValidFrames = fus.PDISequence.readOne( ...
                    fileId, "uint32=>uint32", filePath);
                header.RejectedFrames = fus.PDISequence.readOne( ...
                    fileId, "uint32=>uint32", filePath);
            elseif header.Version == 2
                header.TimestampUnixUs = fus.PDISequence.readOne( ...
                    fileId, "uint64=>uint64", filePath);
            else
                error("fUS:PDIUnsupportedVersion", ...
                    "不支持的PDI版本%d：%s", header.Version, filePath);
            end
            header.Layout = fus.PDISequence.readOne(fileId, "uint32=>uint32", filePath);
            header.X0Mm = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.DxMm = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.Z0Mm = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.DzMm = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.RequestedNearMm = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.RequestedFarMm = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.PdiReferenceLinear = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.PdiDbMultiplier = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.DisplayGainDb = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.DisplayDynamicRangeDb = fus.PDISequence.readOne(fileId, "double=>double", filePath);
            header.PayloadFloatCount = fus.PDISequence.readOne(fileId, "uint64=>uint64", filePath);
            header.PayloadBytes = fus.PDISequence.readOne(fileId, "uint64=>uint64", filePath);
            fus.PDISequence.readOne(fileId, "uint64=>uint64", filePath);

            expectedCount = uint64(header.Width)*uint64(header.Height);
            info = dir(filePath);
            expectedBytes = uint64(header.HeaderBytes)+header.PayloadBytes;
            if header.HeaderBytes ~= 160 || header.Layout ~= 1 ...
                    || header.PayloadFloatCount ~= expectedCount ...
                    || header.PayloadBytes ~= 4*expectedCount ...
                    || isempty(info) || uint64(info.bytes) ~= expectedBytes
                error("fUS:PDIInvalidHeader", "PDI头部或文件长度无效：%s", filePath);
            end
            if ~isfinite(header.PdiReferenceLinear) ...
                    || header.PdiReferenceLinear <= 0 ...
                    || ~isfinite(header.PdiDbMultiplier) ...
                    || header.PdiDbMultiplier <= 0 ...
                    || ~isfinite(header.DisplayDynamicRangeDb) ...
                    || header.DisplayDynamicRangeDb <= 0
                error("fUS:PDIInvalidDisplayParameters", ...
                    "PDI显示参数无效：%s", filePath);
            end
            clear cleanup
        end

        function value = readOne(fileId, precision, filePath)
            value = fread(fileId, 1, precision);
            if isempty(value)
                error("fUS:PDITruncatedHeader", "PDI头部不完整：%s", filePath);
            end
        end

        function header = emptyHeader()
            header = struct(FilePath="", Version=uint32(0), ...
                HeaderBytes=uint32(0), Width=uint32(0), Height=uint32(0), ...
                Sequence=uint64(0), FirstFrame=uint32(0), LastFrame=uint32(0), ...
                SourceFrames=uint32(0), ValidFrames=uint32(0), ...
                RejectedFrames=uint32(0), TimestampUnixUs=uint64(0), ...
                Layout=uint32(0), X0Mm=0, DxMm=0, Z0Mm=0, DzMm=0, ...
                RequestedNearMm=0, RequestedFarMm=0, PdiReferenceLinear=0, ...
                PdiDbMultiplier=0, DisplayGainDb=0, ...
                DisplayDynamicRangeDb=0, PayloadFloatCount=uint64(0), ...
                PayloadBytes=uint64(0));
        end
    end
end
