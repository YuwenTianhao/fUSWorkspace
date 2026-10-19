%% 运行 fUS Workspace 的静态检查、核心算法测试和界面冒烟测试
testsFolder = fileparts(mfilename("fullpath"));
projectFolder = fileparts(testsFolder);
appFolder = fullfile(projectFolder, "app");
coreFolder = fullfile(projectFolder, "core");
addpath(appFolder, coreFolder, testsFolder);

sourceFiles = [ ...
    string(fullfile(appFolder, "fUSWorkspaceAppV2.m")); ...
    string(fullfile(appFolder, "fUSWorkspaceLayout.m")); ...
    string(fullfile(coreFolder, "+fus", "ImageSequence.m")); ...
    string(fullfile(coreFolder, "+fus", "PDISequence.m")); ...
    string(fullfile(coreFolder, "+fus", "CBVEngine.m")); ...
    string(fullfile(coreFolder, "+fus", "ROIEngine.m")); ...
    string(fullfile(coreFolder, "+fus", "ExperimentPlan.m")); ...
    string(fullfile(coreFolder, "+fus", "FrameRenderer.m"))];
for file = sourceFiles'
    issues = checkcode(file, "-id");
    assert(isempty(issues), "Code Analyzer发现问题：%s", file);
end

results = runtests(fullfile(testsFolder, "testCoreAlgorithms.m"));
assert(all([results.Passed]), "核心算法测试未全部通过。");

app = fUSWorkspaceAppV2();
drawnow;
assert(isvalid(app.getFigure()), "App窗口创建失败。");
assert(strlength(string(app.getFigure().Icon)) > 0, "App窗口图标未设置。");
tables = findall(app.getFigure(), "Type", "UITable");
hasROITable = any(arrayfun(@(item)istable(item.Data) ...
    && all(ismember(["Visible", "ROI", "Pixels"], ...
        string(item.Data.Properties.VariableNames))), tables));
assert(hasROITable, "主窗口缺少可勾选的ROI列表。");
planTables = tables(arrayfun(@(item)istable(item.Data) ...
    && all(ismember(["Start_s", "End_s", "Label"], ...
        string(item.Data.Properties.VariableNames))), tables));
assert(numel(planTables) == 1, "主窗口缺少实验计划列表。");
patchCount = NaN;
textCount = NaN;
for repeat = 1:4
    planTables.CellEditCallback(planTables, []);
    bands = findall(app.getFigure(), "Type", "Patch");
    assert(numel(bands) == 1, "实验计划时间窗在重绘时发生叠加。");
    labels = findall(bands.Parent, "Type", "Text");
    if repeat == 1
        patchCount = numel(bands);
        textCount = numel(labels);
    else
        assert(numel(bands) == patchCount && numel(labels) == textCount, ...
            "实验计划图层或标签在重绘时发生叠加。");
    end
end
app.getFigure().WindowState = "minimized";
app.bringToFront();
assert(app.getFigure().WindowState ~= "minimized", "App窗口未能恢复。");
delete(app);

firstFigure = fUSWorkspaceMatlabApp();
secondFigure = fUSWorkspaceMatlabApp();
assert(firstFigure == secondFigure, "Apps页重复启动时创建了重复窗口。");
firstFigure.WindowState = "minimized";
thirdFigure = fUSWorkspaceMatlabApp();
assert(thirdFigure.WindowState ~= "minimized", "Apps页重复启动未恢复现有窗口。");
entryController = getappdata(firstFigure, "fUSWorkspaceController");
delete(entryController);
clear fUSWorkspaceMatlabApp
disp("全部测试通过。");
