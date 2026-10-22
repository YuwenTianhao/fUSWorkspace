classdef fUSWorkspaceProject < handle
    %FUSWORKSPACEPROJECT 实验共用设置与逐截面状态的持久化。
    % 不持有界面句柄，不读取像素，也不调用CBV算法。

    properties (SetAccess = private)
        RootFolder string
        Data struct
    end

    properties (Access = private)
        LastSaved struct = struct()
    end

    methods
        function project = fUSWorkspaceProject(root, configuration, plan, options)
            arguments
                root (1, 1) string
                configuration (1, 1) struct
                plan table
                options.SourceFile (1, 1) string = ""
            end
            project.RootFolder = string(root);
            stored = fus.ExperimentStore.load(root, SourceFile=options.SourceFile);
            if isempty(stored)
                stored = fus.ExperimentStore.newProject(root);
                stored.Configuration = fus.ExperimentStore.sharedConfiguration(configuration);
                stored.ExperimentPlan = plan;
            end
            project.RootFolder = stored.RootFolder;
            if ~isfield(stored, "ResultRoot")
                stored.ResultRoot = fullfile("fUS分析项目", "结果");
            end
            % 重新扫描可发现新增截面；旧状态按相对路径保留，不依赖盘符。
            resultRoot = fus.ExperimentStore.resolvePath(project.RootFolder, stored.ResultRoot);
            stored.Sections = fus.ExperimentStore.discover( ...
                project.RootFolder, ExcludedFolders=resultRoot);
            if isempty(stored.Sections)
                error("fUS:NoExperimentSections", ...
                    "这个目录及子目录中没有找到PDI或BMP/PNG序列。请选择包含截面的实验目录。");
            end
            if isempty(stored.ExperimentPlan)
                stored.ExperimentPlan = plan;
            end
            stored.ExperimentPlan = fus.ExperimentPlan.normalize(stored.ExperimentPlan);
            if ~isfield(stored, "SourceConfigurations")
                stored.SourceConfigurations = struct();
            end
            project.Data = stored;
        end

        function [configuration, plan] = settings(project, sourceType)
            configuration = project.Data.Configuration;
            plan = project.Data.ExperimentPlan;
            if isfield(project.Data.SourceConfigurations, sourceType)
                source = project.Data.SourceConfigurations.(sourceType);
                names = fieldnames(source);
                for index = 1:numel(names)
                    configuration.(names{index}) = source.(names{index});
                end
            elseif sourceType == "image" ...
                    && isfield(project.Data.SourceConfigurations, "pdi") ...
                    && isfield(configuration, "ConversionMode") ...
                    && configuration.ConversionMode == "linear"
                % PDI是线性功率，但同一实验的显示图不能据此假定为线性。
                configuration.ConversionMode = "unknown";
                configuration.MinimumBaselineGray = 35;
            end
            if sourceType == "pdi"
                configuration.ConversionMode = "linear";
                configuration.MinimumBaselineGray = eps;
            end
        end

        function remember(project, key, state, configuration, plan)
            project.Data.Configuration = fus.ExperimentStore.sharedConfiguration(configuration);
            sourceFields = ["ConversionMode", "DynamicRangeDb", ...
                "Log10PerGray", "MinimumBaselineGray"];
            source = struct();
            for name = sourceFields
                source.(name) = configuration.(name);
            end
            project.Data.SourceConfigurations.(configuration.DataSourceType) = source;
            project.Data.ExperimentPlan = fus.ExperimentPlan.normalize(plan);
            project.Data = fus.ExperimentStore.putState(project.Data, key, state);
            project.Data.LastSectionKey = string(key);
        end

        function state = state(project, key)
            state = fus.ExperimentStore.getState(project.Data, key);
        end

        function folder = resultFolder(project, key)
            resultRoot = fus.ExperimentStore.resolvePath( ...
                project.RootFolder, project.Data.ResultRoot);
            if key == "."
                key = "当前截面";
            end
            folder = fullfile(resultRoot, key);
        end

        function setResultRoot(project, folder)
            project.Data.ResultRoot = fus.ExperimentStore.portablePath( ...
                project.RootFolder, folder);
        end

        function changed = save(project)
            candidate = project.Data;
            % SavedAt由存储层维护，不作为是否需要再次写盘的判据。
            candidate.SavedAt = "";
            changed = ~isequaln(candidate, project.LastSaved);
            if changed
                fus.ExperimentStore.save(project.RootFolder, project.Data);
                project.LastSaved = candidate;
            end
        end
    end
end
