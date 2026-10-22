function tests = testProjectRecovery
%TESTPROJECTRECOVERY 失败切换不污染项目；baseline变化不复用旧曲线。
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
project.Configuration = struct(ActualFPS=2, PlaybackFPS=10, ...
    BaselineStart=0, BaselineEnd=0.5, SpatialAverage=1, TemporalAverage=1, ...
    ConversionMode="linear", MinimumBaselineGray=0);
project.ExperimentPlan = table(0, 1.5, "原项目阶段", ...
    VariableNames=["Start_s", "End_s", "Label"]);
parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.ConversionMode = "linear";
parameters.MinimumBaselineGray = 0;
sequence = fus.ImageSequence(project.Sections(1).DataFolder);
baseline = fus.CBVEngine.computeBaseline(sequence, [0, 0.5], 2, parameters);
baseline.CacheMarker = "original-baseline";
vertices = [0, 0; 0.5, 0; 0.5, 1; 0, 1];
mask = fus.ROIEngine.polygonMask(vertices.*[6, 8], [8, 6], [6, 8]);
roi = struct(Name="原项目ROI", Mask=mask, NormalizedPosition=vertices, Visible=true);
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
testCase.TestData.OriginalState = state;
end

function testUnreadableNewProjectRestoresPreviousAnalysis(testCase)
root = testCase.TestData.Root;
app = fUSWorkspaceAppV2(root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(app));
figureHandle = app.getFigure();
% 失败路径会显示真实uialert，MATLAB要求其父窗口可见。
figureHandle.Visible = "on";
originalImage = imageData(figureHandle);

badRoot = string(tempname);
mkdir(badRoot);
testCase.addTeardown(@()removeFixture(badRoot));
% 真实存在但无法解码的PNG，覆盖“文件夹可扫描、首帧不可读”的失败路径。
copyfile(string(mfilename("fullpath")) + ".m", fullfile(badRoot, "corrupt.png"));
badProject = fus.ExperimentStore.newProject(badRoot);
badProject.Configuration = struct(ActualFPS=4, BaselineStart=0, ...
    BaselineEnd=0.25, SpatialAverage=3, ConversionMode="unknown");
badProject.ExperimentPlan = table(0, 1, "不同项目阶段", ...
    VariableNames=["Start_s", "End_s", "Label"]);
fus.ExperimentStore.save(badRoot, badProject);

app.openExperiment(badRoot);
verifyEqual(testCase, string(sectionDropdown(figureHandle).Value), "section1/SVD");
verifyEqual(testCase, numericField(figureHandle, "实际帧率").Value, 2);
verifyEqual(testCase, numericField(figureHandle, "空间平均 (px)").Value, 1);
verifyEqual(testCase, string(tableWithColumns(figureHandle, ...
    ["Start_s", "End_s", "Label"]).Data.Label), "原项目阶段");
verifyEqual(testCase, string(tableWithColumns(figureHandle, ...
    ["Visible", "ROI", "Pixels"]).Data.ROI), "原项目ROI");
verifyEqual(testCase, imageData(figureHandle), originalImage);
saveProject(figureHandle);
verifyOriginalSection(testCase, fus.ExperimentStore.load(root));
verifyEqual(testCase, string(getpref("fUSWorkspace", "LastExperimentRoot")), root);
end

function testUnreadableSectionDoesNotOverwritePreviousSection(testCase)
root = testCase.TestData.Root;
app = fUSWorkspaceAppV2(root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(app));
figureHandle = app.getFigure();
figureHandle.Visible = "on";
originalImage = imageData(figureHandle);
corruptFrame = fullfile(root, "section2", "SVD", "frames_1_1.bmp");
copyfile(string(mfilename("fullpath")) + ".m", corruptFrame, "f");

switchSection(sectionDropdown(figureHandle), "section2/SVD");
verifyEqual(testCase, string(sectionDropdown(figureHandle).Value), "section1/SVD");
verifyEqual(testCase, numericField(figureHandle, "实际帧率").Value, 2);
verifyEqual(testCase, string(tableWithColumns(figureHandle, ...
    ["Visible", "ROI", "Pixels"]).Data.ROI), "原项目ROI");
verifyEqual(testCase, imageData(figureHandle), originalImage);
saveProject(figureHandle);
stored = fus.ExperimentStore.load(root);
verifyOriginalSection(testCase, stored);
verifyEmpty(testCase, fus.ExperimentStore.getState(stored, "section2/SVD"));
end

function testChangingBaselineRangeDoesNotRestoreOldCurves(testCase)
root = testCase.TestData.Root;
app = fUSWorkspaceAppV2(root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(app));
figureHandle = app.getFigure();
figureHandle.Visible = "off";
switchSection(sectionDropdown(figureHandle), "section2/SVD");
baselineEnd = numericField(figureHandle, "baseline结束 (s)");
baselineEnd.Value = 1;
baselineEnd.ValueChangedFcn(baselineEnd, []);
switchSection(sectionDropdown(figureHandle), "section1/SVD");
saveProject(figureHandle);
stored = fus.ExperimentStore.load(root);
state = fus.ExperimentStore.getState(stored, "section1/SVD");
verifyEqual(testCase, state.AnalysisSignature.BaselineSeconds, [0, 1]);
verifyEqual(testCase, state.Baseline.Indices, [1, 2]);
verifyEqual(testCase, state.Baseline.Signal, 15*ones(8, 6));
verifyFalse(testCase, isfield(state.Baseline, "CacheMarker"));
verifyFalse(testCase, any(state.ROICurveValid));
verifyNotEqual(testCase, state.ROICurveValues, testCase.TestData.OriginalState.ROICurveValues);
end

function verifyOriginalSection(testCase, stored)
verifyEqual(testCase, stored.LastSectionKey, "section1/SVD");
verifyEqual(testCase, stored.Configuration.ActualFPS, 2);
verifyEqual(testCase, stored.Configuration.SpatialAverage, 1);
state = fus.ExperimentStore.getState(stored, "section1/SVD");
original = testCase.TestData.OriginalState;
verifyEqual(testCase, state.Fingerprint, original.Fingerprint);
verifyEqual(testCase, state.ROIs, original.ROIs);
verifyEqual(testCase, state.CurrentIndex, original.CurrentIndex);
verifyEqual(testCase, state.Baseline.CacheMarker, "original-baseline");
verifyEqual(testCase, state.ROICurveValues, original.ROICurveValues, AbsTol=1e-12);
verifyTrue(testCase, state.ROICurveValid);
end

function data = imageData(figureHandle)
handles = findall(figureHandle, "Type", "image");
handles = handles(arrayfun(@(item)item.Visible == "on", handles));
assert(~isempty(handles), "画面应包含可见图像图层。");
% CBV模式同时包含解剖背景与活动叠加，失败恢复需要保留两者及透明度。
data = struct(Colors={arrayfun(@(item)item.CData, handles, UniformOutput=false)}, ...
    Alpha={arrayfun(@(item)item.AlphaData, handles, UniformOutput=false)});
end

function dropdown = sectionDropdown(figureHandle)
controls = findall(figureHandle, "Type", "uidropdown");
dropdown = controls(arrayfun(@(item)any( ...
    string(item.ItemsData) == "section1/SVD"), controls));
assert(isscalar(dropdown), "未找到截面选择器。");
end

function field = numericField(figureHandle, text)
labels = findall(figureHandle, "Type", "uilabel");
label = labels(arrayfun(@(item)isequal(string(item.Text), text), labels));
assert(isscalar(label), "参数标签不唯一。");
fields = findall(label.Parent, "Type", "uinumericeditfield");
sameRow = arrayfun(@(item)isequal(item.Layout.Row, label.Layout.Row), fields);
fields = fields(sameRow);
columns = arrayfun(@(item)min(item.Layout.Column), fields);
fields = fields(columns > max(label.Layout.Column));
columns = columns(columns > max(label.Layout.Column));
field = fields(columns == min(columns));
assert(isscalar(field), "未找到参数输入框。");
end

function value = tableWithColumns(figureHandle, names)
tables = findall(figureHandle, "Type", "uitable");
value = tables(arrayfun(@(item)istable(item.Data) ...
    && all(ismember(names, string(item.Data.Properties.VariableNames))), tables));
assert(isscalar(value), "未找到预期的数据表。");
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
