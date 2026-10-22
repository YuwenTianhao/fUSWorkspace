function tests = testProjectWorkflow
%TESTPROJECTWORKFLOW 用合成截面验证界面回调、自动恢复和统一处理。
tests = functiontests(localfunctions);
end

function setupOnce(~)
root = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(root, "app"), fullfile(root, "core"));
end

function setup(testCase)
hadPreference = ispref("fUSWorkspace", "LastExperimentRoot");
previous = "";
if hadPreference
    previous = getpref("fUSWorkspace", "LastExperimentRoot");
end
testCase.addTeardown(@()restorePreference(hadPreference, previous));
root = string(tempname);
mkdir(root);
testCase.addTeardown(@()removeFixture(root));
for index = 1:2
    folder = fullfile(root, "section" + index, "SVD");
    mkdir(folder);
    for frame = 1:3
        imwrite(uint8(10*index*frame*ones(8, 6)), ...
            fullfile(folder, sprintf("frames_%d_%d.bmp", frame, frame)));
    end
end
project = fus.ExperimentStore.newProject(root);
project.ResultRoot = fullfile("fUS分析项目", "测试结果");
project.Configuration = struct(ActualFPS=2, PlaybackFPS=10, ...
    BaselineStart=0, BaselineEnd=0.5, SpatialAverage=1, TemporalAverage=1, ...
    ConversionMode="linear", MinimumBaselineGray=0);
project.ExperimentPlan = table(0, 1.5, "测试阶段", ...
    VariableNames=["Start_s", "End_s", "Label"]);
parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.ConversionMode = "linear";
parameters.MinimumBaselineGray = 0;
sequence = fus.ImageSequence(project.Sections(1).DataFolder);
baseline = fus.CBVEngine.computeBaseline(sequence, [0, 0.5], 2, parameters);
baseline.CacheMarker = "stored-baseline";
vertices = [0, 0; 0.5, 0; 0.5, 1; 0, 1];
mask = fus.ROIEngine.polygonMask(vertices.*[6, 8], [8, 6], [6, 8]);
roi = struct(Name="left", Mask=mask, NormalizedPosition=vertices, Visible=true);
[times, values] = fus.CBVEngine.calculateROICurves( ...
    sequence, baseline, {mask}, parameters, 2);
state = struct(CurrentIndex=2, ROIs=roi, ROISelectedIndex=1, ...
    Fingerprint=fus.ExperimentStore.fingerprint(sequence.Folder, "image"), ...
    Baseline=baseline, AnalysisSignature=struct(Parameters=parameters, ...
        ActualFPS=2, BaselineSeconds=[0, 0.5]), ...
    ROICurveTimes=times, ROICurveValues=values, ROICurveValid=true, ...
    ROICurveParameters=parameters, ROICurveFPS=2);
project = fus.ExperimentStore.putState(project, "section1/SVD", state);
project.LastSectionKey = "section1/SVD";
fus.ExperimentStore.save(root, project);
testCase.TestData.Root = root;
testCase.TestData.ExpectedCurve = values;
end

function testSharedSettingsAndIndependentROIsSurviveSwitchAndReopen(testCase)
root = testCase.TestData.Root;
app = fUSWorkspaceAppV2(root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(app));
figureHandle = app.getFigure();
figureHandle.Visible = "off";
dropdown = sectionDropdown(figureHandle);
verifyEqual(testCase, string(dropdown.Value), "section1/SVD");
roiTable = tableWithColumns(figureHandle, ["Visible", "ROI", "Pixels"]);
verifyEqual(testCase, string(roiTable.Data.ROI), "left");
verifyEqual(testCase, roiTable.ColumnEditable, [true, true, false]);

% 打开项目时复用已保存的baseline和曲线，而不是覆盖为重新计算结果。
saveProject(figureHandle);
stored = fus.ExperimentStore.load(root);
first = fus.ExperimentStore.getState(stored, "section1/SVD");
verifyEqual(testCase, first.Baseline.CacheMarker, "stored-baseline");
verifyEqual(testCase, first.ROICurveValues, testCase.TestData.ExpectedCurve, AbsTol=1e-12);
verifyTrue(testCase, first.ROICurveValid);

% 重命名和曲线点击均经真实界面回调进入控制器。
roiTable.CellEditCallback(roiTable, struct(Indices=[1, 2], NewData="左侧S1"));
curveAxes = axesWithYLabel(figureHandle, "%ΔPD（线性输入）");
curve = findall(curveAxes, "Type", "line");
verifyNotEmpty(testCase, curve);
curve(1).ButtonDownFcn(curve(1), struct(IntersectionPoint=[1.5, 0, 0]));
switchSection(dropdown, "section2/SVD");
verifyEqual(testCase, height(roiTable.Data), 0);
verifyEqual(testCase, numericField(figureHandle, "实际帧率").Value, 2);
verifyEqual(testCase, numericField(figureHandle, "空间平均 (px)").Value, 1);

fps = numericField(figureHandle, "实际帧率");
fps.Value = 4;
fps.ValueChangedFcn(fps, []);
spatial = numericField(figureHandle, "空间平均 (px)");
spatial.Value = 3;
spatial.ValueChangedFcn(spatial, []);
planTable = tableWithColumns(figureHandle, ["Start_s", "End_s", "Label"]);
planTable.Data.Label(1) = "共用刺激方案";
planTable.CellEditCallback(planTable, []);

switchSection(dropdown, "section1/SVD");
verifyEqual(testCase, string(roiTable.Data.ROI), "左侧S1");
verifyEqual(testCase, numericField(figureHandle, "实际帧率").Value, 4);
verifyEqual(testCase, numericField(figureHandle, "空间平均 (px)").Value, 3);
verifyEqual(testCase, string(planTable.Data.Label), "共用刺激方案");
closeProject(figureHandle);
verifyFalse(testCase, isvalid(app));

stored = fus.ExperimentStore.load(root);
verifyEqual(testCase, stored.Configuration.ActualFPS, 4);
verifyEqual(testCase, stored.Configuration.SpatialAverage, 3);
verifyEqual(testCase, stored.LastSectionKey, "section1/SVD");
first = fus.ExperimentStore.getState(stored, "section1/SVD");
second = fus.ExperimentStore.getState(stored, "section2/SVD");
verifyEqual(testCase, first.CurrentIndex, 3);
verifyEqual(testCase, string(first.ROIs.Name), "左侧S1");
verifyEmpty(testCase, second.ROIs);

reopened = fUSWorkspaceAppV2(root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(reopened));
reopenedFigure = reopened.getFigure();
reopenedFigure.Visible = "off";
verifyEqual(testCase, string(sectionDropdown(reopenedFigure).Value), "section1/SVD");
verifyEqual(testCase, numericField(reopenedFigure, "实际帧率").Value, 4);
verifyEqual(testCase, numericField(reopenedFigure, "空间平均 (px)").Value, 3);
verifyEqual(testCase, string(tableWithColumns(reopenedFigure, ...
    ["Start_s", "End_s", "Label"]).Data.Label), "共用刺激方案");
verifyEqual(testCase, string(tableWithColumns(reopenedFigure, ...
    ["Visible", "ROI", "Pixels"]).Data.ROI), "左侧S1");
switchSection(sectionDropdown(reopenedFigure), "section2/SVD");
verifyEqual(testCase, height(tableWithColumns(reopenedFigure, ...
    ["Visible", "ROI", "Pixels"]).Data), 0);
closeProject(reopenedFigure);

verifyTrue(testCase, isfolder(fullfile(root, "fUS分析项目", "测试结果", "section1", "SVD")));
verifyTrue(testCase, isfolder(fullfile(root, "fUS分析项目", "测试结果", "section2", "SVD")));
end

function testUnifiedProcessingUsesOwnROIsAndExportsSeparateResults(testCase)
root = testCase.TestData.Root;
app = fUSWorkspaceAppV2(root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(app));
app.getFigure().Visible = "off";
report = app.processExperiment(ExportVideos=false, ShowProgress=false);
verifyEqual(testCase, report.Status, ["完成"; "完成"]);
verifyNotEqual(testCase, report.OutputFolder(1), report.OutputFolder(2));
verifyTrue(testCase, all(isfile(fullfile(report.OutputFolder, "analysis.mat"))));
first = load(fullfile(report.OutputFolder(1), "analysis.mat"), "result");
second = load(fullfile(report.OutputFolder(2), "analysis.mat"), "result");
verifyEqual(testCase, numel(first.result.ROIs), 1);
verifyEqual(testCase, first.result.Curves, testCase.TestData.ExpectedCurve, AbsTol=1e-12);
verifyEmpty(testCase, second.result.ROIs);
verifyEmpty(testCase, second.result.Curves);
verifyEqual(testCase, first.result.Configuration.ActualFPS, second.result.Configuration.ActualFPS);
verifyEqual(testCase, first.result.ExperimentPlan, second.result.ExperimentPlan);
verifyEqual(testCase, string(sectionDropdown(app.getFigure()).Value), "section1/SVD");
closeProject(app.getFigure());
stored = fus.ExperimentStore.load(root);
state = fus.ExperimentStore.getState(stored, "section1/SVD");
verifyTrue(testCase, state.ROICurveValid);
verifyEqual(testCase, state.ROICurveValues, testCase.TestData.ExpectedCurve, AbsTol=1e-12);
end

function testComputeCBVOnSectionWithoutROIStillUpdatesTheOverview(testCase)
root = testCase.TestData.Root;
app = fUSWorkspaceAppV2(root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(app));
fig = app.getFigure();
fig.Visible = "off";
selector = sectionDropdown(fig);
switchSection(selector, "section2/SVD");
roiTable = tableWithColumns(fig, ["Visible", "ROI", "Pixels"]);
verifyEqual(testCase, height(roiTable.Data), 0);
buttons = findall(fig, Type="uibutton");
button = buttons(arrayfun(@(item)string(item.Text) == "计算CBV与全部ROI", buttons));
button.ButtonPushedFcn(button, []);
stored = fus.ExperimentStore.load(root);
first = fus.ExperimentStore.getState(stored, "section1/SVD");
second = fus.ExperimentStore.getState(stored, "section2/SVD");
verifyTrue(testCase, first.ROICurveValid);
verifyEqual(testCase, first.ROICurveValues, testCase.TestData.ExpectedCurve, AbsTol=1e-12);
verifyEmpty(testCase, second.ROIs);
verifyEqual(testCase, string(selector.Value), "section2/SVD");
verifyEmpty(testCase, dir(fullfile(root, "**", "analysis.mat")));
end

function testBatchVideosKeepFrameCountAndCodecGeometryForEachSection(testCase)
root = testCase.TestData.Root;
sourceFolders = [fullfile(root, "section1", "SVD"), fullfile(root, "section2", "SVD")];
before = cell(1, numel(sourceFolders));
for index = 1:numel(sourceFolders)
    before{index} = fus.ExperimentStore.fingerprint(sourceFolders(index), "image");
end
app = fUSWorkspaceAppV2(root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(app));
app.getFigure().Visible = "off";
report = app.processExperiment(ExportVideos=true, ShowProgress=false);
verifyEqual(testCase, report.Status, ["完成"; "完成"]);
videoPaths = fullfile(report.OutputFolder, "CBV.mp4");
verifyTrue(testCase, all(isfile(videoPaths)));
verifyNotEqual(testCase, videoPaths(1), videoPaths(2));
for index = 1:height(report)
    settingsPath = fullfile(report.OutputFolder(index), "CBV_settings.mat");
    verifyTrue(testCase, isfile(settingsPath));
    saved = load(settingsPath, "videoExport");
    metadata = saved.videoExport;
    verifyEqual(testCase, string(metadata.SourceFolder), sourceFolders(index));
    verifyEqual(testCase, metadata.FrameCount, 3);
    verifyEqual(testCase, metadata.Mode, "cbv");
    verifyEqual(testCase, metadata.CodecAlignment, 16);
    verifyEqual(testCase, mod(metadata.VideoCanvasSize, 16), [0, 0]);
    reader = VideoReader(videoPaths(index));
    verifyEqual(testCase, [reader.Height, reader.Width], metadata.VideoCanvasSize);
    framesRead = 0;
    while hasFrame(reader)
        frame = readFrame(reader);
        verifyEqual(testCase, size(frame, 1), reader.Height);
        verifyEqual(testCase, size(frame, 2), reader.Width);
        framesRead = framesRead + 1;
    end
    verifyEqual(testCase, framesRead, 3);
    after = fus.ExperimentStore.fingerprint(sourceFolders(index), "image");
    verifyEqual(testCase, after, before{index});
end
closeProject(app.getFigure());
end

function dropdown = sectionDropdown(figureHandle)
controls = findall(figureHandle, "Type", "uidropdown");
dropdown = [];
for index = 1:numel(controls)
    if any(string(controls(index).ItemsData) == "section1/SVD")
        dropdown = controls(index);
        return
    end
end
assert(~isempty(dropdown), "未找到截面选择器。");
end

function field = numericField(figureHandle, labelText)
labels = findall(figureHandle, "Type", "uilabel");
label = labels(arrayfun(@(item)isequal(string(item.Text), labelText), labels));
assert(isscalar(label), "参数标签不唯一：%s", labelText);
fields = findall(label.Parent, "Type", "uinumericeditfield");
sameRow = arrayfun(@(item)isequal(item.Layout.Row, label.Layout.Row), fields);
fields = fields(sameRow);
columns = arrayfun(@(item)min(item.Layout.Column), fields);
fields = fields(columns > max(label.Layout.Column));
columns = columns(columns > max(label.Layout.Column));
field = fields(columns == min(columns));
assert(isscalar(field), "未找到参数输入框：%s", labelText);
end

function value = tableWithColumns(figureHandle, names)
tables = findall(figureHandle, "Type", "uitable");
value = tables(arrayfun(@(item)istable(item.Data) ...
    && all(ismember(names, string(item.Data.Properties.VariableNames))), tables));
assert(isscalar(value), "未找到预期的数据表。");
end

function curveAxes = axesWithYLabel(figureHandle, labelText)
allAxes = findall(figureHandle, "Type", "axes");
curveAxes = allAxes(arrayfun(@(item)string(item.YLabel.String) == labelText, allAxes));
assert(isscalar(curveAxes), "未找到ROI曲线坐标轴。");
end

function switchSection(dropdown, key)
dropdown.Value = key;
dropdown.ValueChangedFcn(dropdown, struct(Value=key));
drawnow;
end

function saveProject(figureHandle)
buttons = findall(figureHandle, "Type", "uibutton");
button = buttons(arrayfun(@(item)string(item.Text) == "保存项目", buttons));
assert(isscalar(button));
button.ButtonPushedFcn(button, []);
end

function closeProject(figureHandle)
figureHandle.CloseRequestFcn(figureHandle, []);
end

function deleteApp(app)
if isvalid(app)
    delete(app);
end
end

function removeFixture(root)
if isfolder(root)
    rmdir(root, "s");
end
end

function restorePreference(hadPreference, previous)
if hadPreference
    setpref("fUSWorkspace", "LastExperimentRoot", previous);
elseif ispref("fUSWorkspace", "LastExperimentRoot")
    rmpref("fUSWorkspace", "LastExperimentRoot");
end
end
