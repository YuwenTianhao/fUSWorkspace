classdef ExperimentPlan
    %EXPERIMENTPLAN 实验阶段表的默认值、校验和时间查询。

    methods (Static)
        function plan = defaultPlan()
            plan = fus.ExperimentPlan.defaultHindpawPlan();
        end

        function plan = defaultHindpawPlan()
            plan = table( ...
                [0; 60; 90; 150; 180], ...
                [60; 90; 150; 180; 240], ...
                ["静息baseline"; "右后爪夹捏刺激1"; "休息1"; ...
                 "右后爪夹捏刺激2"; "休息2"], ...
                VariableNames=["Start_s", "End_s", "Label"]);
        end

        function plan = defaultWhiskerPlan()
            plan = table( ...
                [0; 180; 210; 270; 300; 360; 390; 450; 480], ...
                [180; 210; 270; 300; 360; 390; 450; 480; 540], ...
                ["静息1"; "右侧胡须触摸1"; "静息2"; "左侧胡须触摸1"; ...
                 "静息3"; "右侧胡须触摸2"; "静息4"; "左侧胡须触摸2"; "静息5"], ...
                VariableNames=["Start_s", "End_s", "Label"]);
        end

        function plan = normalize(plan)
            if ~istable(plan) || width(plan) < 3
                error("fUS:InvalidExperimentPlan", ...
                    "实验计划必须包含开始、结束和阶段三列。");
            end
            plan = plan(:, 1:3);
            plan.Properties.VariableNames = ["Start_s", "End_s", "Label"];
            plan.Start_s = double(plan.Start_s);
            plan.End_s = double(plan.End_s);
            plan.Label = string(plan.Label);

            valid = isfinite(plan.Start_s) & isfinite(plan.End_s) ...
                & plan.Start_s >= 0 & plan.End_s > plan.Start_s ...
                & strlength(strtrim(plan.Label)) > 0;
            if ~all(valid)
                error("fUS:InvalidExperimentPlan", ...
                    "每个实验阶段都需要有效的开始时间、结束时间和名称。");
            end
            plan = sortrows(plan, "Start_s");
            if height(plan) > 1 && any(plan.Start_s(2:end) < plan.End_s(1:end - 1))
                error("fUS:OverlappingExperimentPlan", ...
                    "实验阶段时间不能重叠；相邻阶段可以共用一个结束/开始时间。");
            end
        end

        function phase = phaseAt(plan, seconds)
            plan = fus.ExperimentPlan.normalize(plan);
            phase = fus.ExperimentPlan.phaseAtNormalized(plan, seconds);
        end

        function phase = phaseAtNormalized(plan, seconds)
            % 调用者已经校验并排序计划时，播放期间无需重复处理表格。
            match = find(seconds >= plan.Start_s & seconds < plan.End_s, ...
                1, "first");
            if isempty(match) && ~isempty(plan) && seconds == max(plan.End_s)
                match = find(plan.End_s == seconds, 1, "last");
            end
            if ~isempty(match)
                phase = string(plan.Label(match));
            elseif ~isempty(plan) && seconds > max(plan.End_s)
                phase = "实验计划结束";
            else
                phase = "";
            end
        end
    end
end
