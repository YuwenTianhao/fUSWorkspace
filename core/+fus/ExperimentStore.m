classdef ExperimentStore
    %EXPERIMENTSTORE 一个实验共用参数，各截面分别保存 ROI 与浏览进度。
    %
    % Configuration 和 ExperimentPlan 属于实验；SectionStates.State 属于
    % 截面，内容由 App 提供。项目中的 Key 是相对实验根目录的路径，移动
    % 整个实验文件夹后仍可定位数据。原始数据文件不会被修改。

    methods (Static)
        function project = newProject(root)
            root = fus.ExperimentStore.absoluteRoot(root);
            project = struct(Version="2.0", RootFolder=root, ...
                Configuration=struct(), ExperimentPlan=table(), ...
                Sections=fus.ExperimentStore.discover(root), ...
                SectionStates=struct("Key", {}, "State", {}), ...
                LastSectionKey="", SavedAt="");
        end

        function sections = discover(root, options)
            arguments
                root {mustBeTextScalar}
                options.ExcludedFolders string = strings(0, 1)
            end
            root = fus.ExperimentStore.absoluteRoot(root);
            excluded = strings(0, 1);
            for excludedPath = reshape(options.ExcludedFolders, 1, [])
                folder = fus.ExperimentStore.resolvePath(root, excludedPath);
                if isfolder(folder)
                    folder = fus.ExperimentStore.absoluteRoot(folder);
                end
                % 用户可以将实验根目录本身设为输出根目录；只排除严格子目录。
                if startsWith(folder, root + filesep)
                    excluded(end + 1) = folder; %#ok<AGROW>
                end
            end
            sections = fus.ExperimentStore.scanFolder(root, root, 0, excluded);
            if isempty(sections)
                return
            end
            keys = string({sections.Key});
            orderKeys = strings(size(keys));
            for index = 1:numel(keys)
                parts = regexp(char(lower(keys(index))), '\d+|\D+', 'match');
                for part = 1:numel(parts)
                    if all(isstrprop(parts{part}, 'digit'))
                        parts{part} = sprintf('%020.0f', str2double(parts{part}));
                    end
                end
                orderKeys(index) = string(strjoin(parts, ''));
            end
            [~, order] = sort(orderKeys);
            sections = sections(order);
        end

        function path = projectPath(root)
            path = fullfile(string(root), "fUS分析项目", "experiment.mat");
        end

        function save(root, project)
            root = fus.ExperimentStore.absoluteRoot(root);
            project = fus.ExperimentStore.validate(project, root);
            project.SavedAt = string(datetime("now", Format="yyyy-MM-dd HH:mm:ss"));
            destination = fus.ExperimentStore.projectPath(root);
            folder = string(fileparts(destination));
            if ~isfolder(folder)
                mkdir(folder);
            end
            temporary = string(tempname(folder)) + ".mat";
            temporaryBackup = string(tempname(folder)) + ".bak";
            cleanup = onCleanup(@()fus.ExperimentStore.removeTemporary( ...
                [temporary, temporaryBackup]));
            builtin('save', temporary, 'project', '-v7.3');
            if isfile(destination)
                [success, message] = copyfile(destination, temporaryBackup, 'f');
                if ~success
                    error("fUS:ProjectSaveFailed", "无法备份分析项目：%s", message);
                end
                [success, message] = movefile(temporaryBackup, destination + ".bak", 'f');
                if ~success
                    error("fUS:ProjectSaveFailed", "无法更新分析项目备份：%s", message);
                end
            end
            [success, message] = movefile(temporary, destination, 'f');
            if ~success
                error("fUS:ProjectSaveFailed", "无法保存分析项目：%s", message);
            end
            clear cleanup
        end

        function autosave(root, project)
            fus.ExperimentStore.save(root, project);
        end

        function project = load(root, options)
            arguments
                root (1, 1) string
                options.SourceFile (1, 1) string = ""
            end
            root = fus.ExperimentStore.absoluteRoot(root);
            path = fus.ExperimentStore.projectPath(root);
            if strlength(options.SourceFile) > 0
                path = options.SourceFile;
                if ~isfile(path)
                    error("fUS:ProjectSourceNotFound", "所选分析项目文件不存在：%s", path);
                end
            end
            if ~isfile(path)
                project = [];
                return
            end
            % 备份使用 .bak 扩展名，必须明确按 MAT 格式读取。
            saved = builtin('load', path, 'project', '-mat');
            if ~isfield(saved, 'project')
                error("fUS:InvalidProject", "文件中没有有效的分析项目：%s", path);
            end
            project = fus.ExperimentStore.validate(saved.project, root);
        end

        function project = putState(project, key, state)
            key = string(key);
            if ~isstruct(state) || ~isscalar(state)
                error("fUS:InvalidSectionState", "截面状态必须是单个结构体。");
            end
            if ~any(string({project.Sections.Key}) == key)
                error("fUS:UnknownSection", "截面不属于当前实验：%s", key);
            end
            index = find(string({project.SectionStates.Key}) == key, 1);
            entry = struct(Key=key, State=state);
            if isempty(index)
                project.SectionStates(end + 1) = entry;
            else
                project.SectionStates(index) = entry;
            end
        end

        function state = getState(project, key)
            index = find(string({project.SectionStates.Key}) == string(key), 1);
            if isempty(index)
                state = [];
            else
                state = project.SectionStates(index).State;
            end
        end

        function configuration = sharedConfiguration(configuration)
            % 画布尺寸、宽高比和数据类型取决于截面，不向其他截面传播。
            fields = intersect(fieldnames(configuration), ...
                {'Width', 'Height', 'LockRatio', 'DataSourceType', 'BrainMask'});
            configuration = rmfield(configuration, fields);
        end

        function path = portablePath(root, path)
            % 实验内输出目录保存为相对路径；用户指定的外部目录保持绝对路径。
            root = string(root);
            path = string(path);
            prefix = root + filesep;
            if path == root
                path = ".";
            elseif startsWith(path, prefix)
                path = replace(extractAfter(path, strlength(prefix)), filesep, "/");
            end
        end

        function path = resolvePath(root, path)
            path = string(path);
            if path == "."
                path = string(root);
            elseif ~startsWith(path, "/") && isempty(regexp(path, '^[A-Za-z]:[\\/]', 'once')) ...
                    && ~startsWith(path, "\\")
                parts = split(replace(path, "\", "/"), "/");
                if any(parts == "..")
                    error("fUS:InvalidProjectPath", "项目相对路径不能包含上级目录。");
                end
                path = fullfile(string(root), path);
            end
        end

        function identity = fingerprint(folder, sourceType)
            % 文件清单签名用于识别数据更换；不读取大型图像或 PDI 像素。
            entries = dir(string(folder));
            entries = entries(~[entries.isdir]);
            names = string({entries.name});
            if string(sourceType) == "pdi"
                keep = endsWith(lower(names), ".pdi");
            else
                keep = endsWith(lower(names), ".bmp") | endsWith(lower(names), ".png");
            end
            keep = keep & ~startsWith(names, ".");
            entries = entries(keep);
            [names, order] = sort(string({entries.name}));
            entries = entries(order);
            identity = struct(SourceType=string(sourceType), Count=numel(entries), ...
                Names=names(:), Bytes=double([entries.bytes])', ...
                Modified=double([entries.datenum])');
        end
    end

    methods (Static, Access = private)
        function sections = scanFolder(root, folder, depth, excluded)
            sections = struct("Name", {}, "DataFolder", {}, "DataSourceType", {}, "Key", {});
            if any(string(folder) == excluded)
                return
            end
            entries = dir(folder);
            names = string({entries.name});
            files = names(~[entries.isdir] & ~startsWith(names, "."));
            sourceType = "";
            if any(endsWith(lower(files), ".pdi"))
                sourceType = "pdi";
            elseif any(endsWith(lower(files), ".bmp") | endsWith(lower(files), ".png"))
                sourceType = "image";
            end
            % 两种序列读取器都会优先进入 SVD 子目录；父目录中的概览图
            % 不能因此被登记成第二份截面，否则两个条目会读取相同的数据。
            if strlength(sourceType) > 0 && ~isfolder(fullfile(folder, "SVD"))
                key = fus.ExperimentStore.portablePath(root, folder);
                if key == "."
                    [~, name] = fileparts(root);
                else
                    name = key;
                end
                sections(end + 1) = struct(Name=string(name), DataFolder=string(folder), ...
                    DataSourceType=sourceType, Key=key);
            end
            if depth >= 5
                return
            end
            directories = names([entries.isdir] & ~startsWith(names, "."));
            for name = directories
                if fus.ExperimentStore.isOutputFolder(name)
                    continue
                end
                children = fus.ExperimentStore.scanFolder( ...
                    root, fullfile(folder, name), depth + 1, excluded);
                sections = [sections, children]; %#ok<AGROW>
            end
        end

        function skip = isOutputFolder(name)
            name = lower(string(name));
            skip = any(name == ["fus分析项目", "fus工作区结果", "cbv结果", ...
                "assets", "resources", "release", "results", "result", ...
                "output", "outputs", "exports", "export", "node_modules"]) ...
                || contains(name, "分析结果");
        end

        function root = absoluteRoot(root)
            root = string(root);
            if ~isscalar(root) || strlength(root) == 0 || ~isfolder(root)
                error("fUS:ExperimentFolderNotFound", "实验文件夹不存在：%s", root);
            end
            [success, attributes] = fileattrib(root); %#ok<FILEATTRIB>
            if ~success
                error("fUS:ExperimentFolderNotFound", "无法读取实验文件夹：%s", root);
            end
            root = string(attributes.Name);
        end

        function project = validate(project, root)
            required = ["Version", "Configuration", "ExperimentPlan", ...
                "Sections", "SectionStates", "LastSectionKey"];
            if ~isstruct(project) || ~isscalar(project) || ~all(isfield(project, required)) ...
                    || string(project.Version) ~= "2.0" ...
                    || ~isstruct(project.Configuration) || ~isscalar(project.Configuration) ...
                    || ~istable(project.ExperimentPlan) ...
                    || ~isstruct(project.Sections) || ~isstruct(project.SectionStates) ...
                    || ~all(isfield(project.Sections, ...
                        ["Name", "DataFolder", "DataSourceType", "Key"])) ...
                    || ~all(isfield(project.SectionStates, ["Key", "State"]))
                error("fUS:InvalidProject", "分析项目格式不正确或版本不受支持。");
            end
            if ~isempty(project.ExperimentPlan)
                project.ExperimentPlan = fus.ExperimentPlan.normalize(project.ExperimentPlan);
            end
            project.RootFolder = root;
            keys = strings(1, numel(project.Sections));
            for index = 1:numel(project.Sections)
                key = string(project.Sections(index).Key);
                if ~isscalar(key) || strlength(key) == 0 || startsWith(key, "/") ...
                        || contains(key, "\") || ~isempty(regexp(key, '^[A-Za-z]:', 'once'))
                    error("fUS:InvalidProjectPath", "截面路径必须是相对实验目录的路径。");
                end
                keys(index) = key;
                project.Sections(index).DataFolder = fus.ExperimentStore.resolvePath(root, key);
                if ~any(string(project.Sections(index).DataSourceType) == ["pdi", "image"])
                    error("fUS:InvalidProject", "截面数据类型不受支持。");
                end
            end
            if numel(unique(keys)) ~= numel(keys)
                error("fUS:InvalidProject", "分析项目包含重复截面。");
            end
            project.Configuration = fus.ExperimentStore.sharedConfiguration(project.Configuration);
        end

        function removeTemporary(paths)
            for path = paths
                if isfile(path)
                    delete(path);
                end
            end
        end
    end
end
