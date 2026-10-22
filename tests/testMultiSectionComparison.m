function tests = testMultiSectionComparison
%TESTMULTISECTIONCOMPARISON 共同时间轴下的多截面画面、ROI总览及播放点。
tests = functiontests(localfunctions);
end

function setupOnce(~)
root = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(root, "app"), fullfile(root, "core"));
end

function setup(testCase)
hadPreference = ispref("fUSWorkspace", "LastExperimentRoot");
previous = getpref("fUSWorkspace", "LastExperimentRoot", "");
testCase.addTeardown(@()restorePreference(hadPreference, previous));
root = string(tempname);
mkdir(root);
testCase.addTeardown(@()removeFixture(root));
for section = 1:3
    folder = fullfile(root, "section" + section, "SVD");
    mkdir(folder);
    for frame = 1:3
        value = 10*section + 5*section^2*(frame-1);
        imwrite(uint8(value*ones(8, 6)), ...
            fullfile(folder, sprintf("frames_%d_%d.bmp", frame, frame)));
    end
end
project = fus.ExperimentStore.newProject(root);
project.Configuration = struct(ActualFPS=2, PlaybackFPS=10, ...
    BaselineStart=0, BaselineEnd=0.5, SpatialAverage=1, TemporalAverage=1, ...
    ConversionMode="linear", MinimumBaselineGray=0, BrainMask=true, ...
    ViewMode="cbv", ShowAllSectionCurves=true, ...
    ComparisonKeys=["section1/SVD", "section2/SVD", "section3/SVD"]);
project.ExperimentPlan = table([0; 0.5; 1], [0.5; 1; 1.5], ...
    ["baseline"; "刺激"; "休息"], VariableNames=["Start_s", "End_s", "Label"]);
parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.ConversionMode = "linear";
parameters.MinimumBaselineGray = 0;
vertices = { ...
    [0, 0; 0.4, 0; 0.4, 1; 0, 1], ...
    [0.6, 0; 1, 0; 1, 1; 0.6, 1], ...
    [0.2, 0.2; 0.8, 0.2; 0.8, 0.8; 0.2, 0.8]};
for section = 1:3
    key = "section" + section + "/SVD";
    sequence = fus.ImageSequence(fullfile(root, key));
    baseline = fus.CBVEngine.computeBaseline(sequence, [0, 0.5], 2, parameters);
    mask = fus.ROIEngine.polygonMask(vertices{section}, [8, 6], [1, 1]);
    roi = struct(Name=char("ROI_S" + section), Mask=mask, ...
        NormalizedPosition=vertices{section}, Visible=true);
    [times, values] = fus.CBVEngine.calculateROICurves(sequence, baseline, ...
        {mask}, parameters, 2);
    state = struct(CurrentIndex=2, ROIs=roi, ROISelectedIndex=1, ...
        DataSourceType="image", Baseline=baseline, ...
        Configuration=struct(Width=6, Height=8, LockRatio=false, BrainMask=true), ...
        Fingerprint=fus.ExperimentStore.fingerprint(sequence.Folder, "image"), ...
        AnalysisSignature=struct(Parameters=parameters, ActualFPS=2, BaselineSeconds=[0, 0.5]), ...
        ROICurveTimes=times, ROICurveValues=values, ROICurveValid=true, ...
        ROICurveParameters=parameters, ROICurveFPS=2, ...
        UserDisplayMask=mask, UserDisplayMaskVertices=vertices{section});
    project = fus.ExperimentStore.putState(project, key, state);
end
project.LastSectionKey = "section1/SVD";
fus.ExperimentStore.save(root, project);
testCase.TestData.Root = root;
testCase.TestData.InitialProject = project;
end

function testGlobalROIOverviewAndCurvesRemainWhenChangingSections(testCase)
app = openFixture(testCase);
figureHandle = app.getFigure();
globalTable = tableWithColumns(figureHandle, ["SectionKey", "Section", "ROI", "Status", "ROIIndex"]);
verifyEqual(testCase, height(globalTable.Data), 3);
verifyEqual(testCase, sort(string(globalTable.Data.ROI)), ["ROI_S1"; "ROI_S2"; "ROI_S3"]);
verifyEqual(testCase, globalTable.Data.Status, repmat("已计算", 3, 1));
verifyNumElements(testCase, fullCurves(figureHandle), 3);
points = findall(figureHandle, Tag="fUSCurrentPoint");
verifyNumElements(testCase, points, 3);
verifyEqual(testCase, sort([points.XData]), [1, 1, 1], AbsTol=1e-12);
verifyEqual(testCase, sort([points.YData]), [50, 100, 150], AbsTol=1e-12);
% 曲线与播放点必须落在真实可见的坐标范围内，不能只更新坐标却被裁掉。
verifyGreaterThanOrEqual(testCase, points(1).Parent.YLim(2), 300);
verifyLessThanOrEqual(testCase, points(1).Parent.YLim(1), 0);

selector = sectionDropdown(figureHandle);
switchSection(selector, "section3/SVD");
current = tableWithColumns(figureHandle, ["Visible", "ROI", "Pixels"]);
verifyEqual(testCase, string(current.Data.ROI), "ROI_S3");
verifyEqual(testCase, height(globalTable.Data), 3);
verifyNumElements(testCase, fullCurves(figureHandle), 3);

% 项目总览按截面定位原有ROI，不复制到当前截面的坐标中。
row = find(globalTable.Data.SectionKey == "section1/SVD", 1);
globalTable.CellSelectionCallback(globalTable, struct(Indices=[row, 3]));
verifyEqual(testCase, string(selector.Value), "section1/SVD");
verifyEqual(testCase, string(current.Data.ROI), "ROI_S1");
verifyEqual(testCase, current.Selection, [1, 2]);
verifyEqual(testCase, height(globalTable.Data), 3);

showAll = checkbox(figureHandle, "显示跨截面ROI曲线");
showAll.Value = false;
showAll.ValueChangedFcn(showAll, []);
verifyNumElements(testCase, fullCurves(figureHandle), 1);
verifyEqual(testCase, height(globalTable.Data), 3);
showAll.Value = true;
showAll.ValueChangedFcn(showAll, []);
verifyNumElements(testCase, fullCurves(figureHandle), 3);
saveProject(figureHandle);
stored = fus.ExperimentStore.load(testCase.TestData.Root);
for section = 1:3
    state = fus.ExperimentStore.getState(stored, "section" + section + "/SVD");
    verifyEqual(testCase, string(state.ROIs.Name), "ROI_S" + section);
    verifyEqual(testCase, numel(state.ROIs), 1);
    verifyEqual(testCase, state.ROICurveValues, [0; 50*section; 100*section], AbsTol=1e-12);
end
end

function testMultipleImagesAndMovingPointsShareTheSameTime(testCase)
app = openFixture(testCase);
figureHandle = app.getFigure();
list = findall(figureHandle, Type="uilistbox");
verifyNumElements(testCase, list, 1);
verifyEqual(testCase, string(list.Enable), "on");
keys = ["section1/SVD", "section2/SVD", "section3/SVD"];
list.Value = keys;
list.ValueChangedFcn(list, struct(Value=keys));
drawnow;
panels = findall(figureHandle, Type="uipanel");
imagePanels = panels(arrayfun(@(item)any(startsWith(string(item.Title), ...
    ["section1 ·", "section2 ·", "section3 ·"])), panels));
verifyNumElements(testCase, imagePanels, 3);
verifyTrue(testCase, all(arrayfun(@(item)item.Visible == "on", imagePanels)));

view = viewDropdown(figureHandle);
view.Value = "browser";
view.ValueChangedFcn(view, struct(Value="browser"));
curves = fullCurves(figureHandle);
local = curves(arrayfun(@(item)isnumeric(item.UserData) && isscalar(item.UserData), curves));
verifyNumElements(testCase, local, 1);
local.ButtonDownFcn(local, struct(IntersectionPoint=[1.5, 100, 0]));
images = findall(figureHandle, Type="image");
images = images(arrayfun(@(item)item.Visible == "on" && ndims(item.CData) == 3, images));
verifyNumElements(testCase, images, 3);
values = sort(arrayfun(@(item)double(item.CData(1, 1, 1)), images));
verifyEqual(testCase, values(:)', [20, 60, 120]);
points = findall(figureHandle, Tag="fUSCurrentPoint");
verifyNumElements(testCase, points, 3);
verifyEqual(testCase, [points.XData], [1.5, 1.5, 1.5], AbsTol=1e-12);
verifyEqual(testCase, sort([points.YData]), [100, 200, 300], AbsTol=1e-12);
paths = findall(figureHandle, Tag="fUSCurvePast");
verifyTrue(testCase, all(arrayfun(@(item)numel(item.XData) == 3, paths)));

% 每个截面独立保存手绘掩膜；它们不改变已计算的ROI数值。
switchSection(sectionDropdown(figureHandle), "section2/SVD");
view.Value = "cbv";
view.ValueChangedFcn(view, struct(Value="cbv"));
curves = fullCurves(figureHandle);
local = curves(arrayfun(@(item)isnumeric(item.UserData) && isscalar(item.UserData), curves));
local.ButtonDownFcn(local, struct(IntersectionPoint=[1.5, 200, 0]));
activity = findall(figureHandle, Type="image");
activity = activity(arrayfun(@(item)isequal(size(item.CData), [8, 6]), activity));
verifyNumElements(testCase, activity, 1);
verifyEqual(testCase, activity.AlphaData(:, 1:3), zeros(8, 3));
verifyGreaterThan(testCase, max(activity.AlphaData(:, 5:6), [], "all"), 0);
saveProject(figureHandle);
stored = fus.ExperimentStore.load(testCase.TestData.Root);
for section = 1:3
    key = "section" + section + "/SVD";
    state = fus.ExperimentStore.getState(stored, key);
    original = fus.ExperimentStore.getState(testCase.TestData.InitialProject, key);
    verifyEqual(testCase, state.UserDisplayMask, original.UserDisplayMask);
    verifyEqual(testCase, state.UserDisplayMaskVertices, original.UserDisplayMaskVertices);
    verifyEqual(testCase, state.ROICurveValues, original.ROICurveValues, AbsTol=1e-12);
end
end

function testImageWorkspaceUsesMostWidthAndSettingsCanCollapse(testCase)
app = openFixture(testCase);
figureHandle = app.getFigure();
% 可见窗口才更新MATLAB布局的像素位置；另外两项测试只验证数据回调。
figureHandle.Visible = "on";
drawnow;
panels = findall(figureHandle, Type="uipanel");
main = panels(arrayfun(@(item)startsWith(string(item.Title), "section1 ·"), panels));
verifyNumElements(testCase, main, 1);
imageGrid = main.Parent;
workspace = imageGrid.Parent;
body = workspace.Parent;
verifyGreaterThan(testCase, workspace.Position(3)/body.Position(3), 0.65);
verifyGreaterThan(testCase, imageGrid.Position(4)/workspace.Position(4), 0.60);
verifyEqual(testCase, body.ColumnWidth{2}, 320);
buttons = findall(figureHandle, Type="uibutton");
toggle = buttons(arrayfun(@(item)string(item.Text) == "参数 / ROI", buttons));
verifyNumElements(testCase, toggle, 1);
toggle.ButtonPushedFcn(toggle, []);
verifyEqual(testCase, body.ColumnWidth{2}, 0);
% uifigure的浏览器布局异步更新，drawnow本身只提交这一轮变化。
deadline = tic;
while workspace.Position(3)/body.Position(3) <= 0.90 && toc(deadline) < 3
    pause(0.05);
    drawnow;
end
verifyGreaterThan(testCase, workspace.Position(3)/body.Position(3), 0.90);
toggle.ButtonPushedFcn(toggle, []);
verifyEqual(testCase, body.ColumnWidth{2}, 320);
end

function testEditorSelectionKeepsPanelSlotsAndSupportsPreciseAnnotation(testCase)
app = openFixture(testCase);
fig = app.getFigure();
keys = ["section1", "section2", "section3"];
before = zeros(3, 2);
for index = 1:3
    panel = imagePanel(fig, keys(index));
    before(index, :) = [panel.Layout.Row, panel.Layout.Column];
    verifyEqual(testCase, panel.BackgroundColor, [0.025, 0.03, 0.04]);
end
% 点击第二幅图只选择编辑对象，不交换截面显示顺序。
panel = imagePanel(fig, "section2");
picture = findall(panel, Type="image");
picture.ButtonDownFcn(picture, []);
verifyEqual(testCase, string(sectionDropdown(fig).Value), "section2/SVD");
for index = 1:3
    panel = imagePanel(fig, keys(index));
    verifyEqual(testCase, [panel.Layout.Row, panel.Layout.Column], before(index, :));
end
buttons = findall(fig, Type="uibutton");
verifyFalse(testCase, any(ismember(string({buttons.Text}), ["‹", "›"])));
panel = imagePanel(fig, "section2");
verifyTrue(testCase, contains(string(panel.Title), "正在标注"));
polygon = findall(panel, Type="images.roi.Polygon");
polygon = polygon(arrayfun(@(item)string(item.Label) == "ROI_S2", polygon));
verifyEqual(testCase, string(polygon.LabelVisible), "off");
verifyLessThanOrEqual(testCase, polygon.LineWidth, 1.1);
position = polygon.Position;
axesHandle = polygon.Parent;
verifyEqual(testCase, axesHandle.Color, [0.025, 0.03, 0.04]);
dropdowns = findall(fig, Type="uidropdown");
tool = dropdowns(arrayfun(@(item)any(string(item.ItemsData) == "edit"), dropdowns));
for mode = ["zoom", "pan", "edit"]
    tool.Value = mode;
    tool.ValueChangedFcn(tool, struct(Value=mode));
    if mode == "edit"
        verifyEqual(testCase, string(polygon.InteractionsAllowed), "all");
    else
        verifyEqual(testCase, string(polygon.InteractionsAllowed), "none");
    end
end
zoom(axesHandle, 2);
zoomed = diff(axesHandle.XLim);
button = buttons(arrayfun(@(item)string(item.Text) == "缩小", buttons));
button.ButtonPushedFcn(button, []);
verifyGreaterThan(testCase, diff(axesHandle.XLim), zoomed);
verifyEqual(testCase, polygon.Position, position, AbsTol=1e-12);
button = buttons(arrayfun(@(item)string(item.Text) == "适应视野", buttons));
button.ButtonPushedFcn(button, []);
verifyEqual(testCase, axesHandle.XLim, [0, 6], AbsTol=1e-12);
verifyEqual(testCase, axesHandle.YLim, [0, 8], AbsTol=1e-12);
labels = checkbox(fig, "ROI名称");
labels.Value = true;
labels.ValueChangedFcn(labels, []);
verifyEqual(testCase, string(polygon.LabelVisible), "on");
focusButton = buttons(arrayfun(@(item)string(item.Text) == "放大标注", buttons));
focusButton.ButtonPushedFcn(focusButton, []);
verifyEqual(testCase, [panel.Layout.Row, panel.Layout.Column], [1, 1]);
verifyEqual(testCase, string(imagePanel(fig, "section1").Visible), "off");
verifyEqual(testCase, string(focusButton.Text), "恢复对照");
focusButton.ButtonPushedFcn(focusButton, []);
for index = 1:3
    panel = imagePanel(fig, keys(index));
    verifyEqual(testCase, [panel.Layout.Row, panel.Layout.Column], before(index, :));
end
end

function panel = imagePanel(fig, key)
panels = findall(fig, Type="uipanel");
panel = panels(arrayfun(@(item)startsWith(string(item.Title), key + " ·"), panels));
assert(isscalar(panel), "没有找到截面画面。");
end

function testComputeCBVRefreshesEveryOverviewROIIncludingHiddenAndUnselectedSections(testCase)
project = testCase.TestData.InitialProject;
project.Configuration.ComparisonKeys = "section1/SVD";
for section = 1:3
    key = "section" + section + "/SVD";
    state = fus.ExperimentStore.getState(project, key);
    % 即使缓存标记有效，也应按用户的主动计算请求重算，而不是沿用假值。
    state.ROICurveValues(:) = -999;
    state.ROICurveValid = true;
    state.ROIs.Visible = section ~= 3;
    project = fus.ExperimentStore.putState(project, key, state);
end
fus.ExperimentStore.save(testCase.TestData.Root, project);
app = openFixture(testCase);
fig = app.getFigure();
fig.Visible = "on"; % 覆盖真实点击时的统一进度窗口路径。
polygons = findall(imagePanel(fig, "section1"), Type="images.roi.Polygon");
axesHandle = polygons(1).Parent;
axesHandle.XLim = [1, 4];
axesHandle.YLim = [2, 7];
buttons = findall(fig, Type="uibutton");
button = buttons(arrayfun(@(item)string(item.Text) == "计算CBV与全部ROI", buttons));
verifyNumElements(testCase, button, 1);
button.ButtonPushedFcn(button, []);
stored = fus.ExperimentStore.load(testCase.TestData.Root);
for section = 1:3
    key = "section" + section + "/SVD";
    state = fus.ExperimentStore.getState(stored, key);
    original = fus.ExperimentStore.getState(testCase.TestData.InitialProject, key);
    verifyTrue(testCase, state.ROICurveValid);
    verifyEqual(testCase, state.ROICurveValues, original.ROICurveValues, AbsTol=1e-12);
    verifyEqual(testCase, state.ROIs.Visible, section ~= 3);
end
overview = tableWithColumns(fig, ["SectionKey", "Section", "ROI", "Status", "ROIIndex"]);
verifyEqual(testCase, overview.Data.Status, repmat("已计算", 3, 1));
verifyEqual(testCase, string(sectionDropdown(fig).Value), "section1/SVD");
verifyEqual(testCase, string(findall(fig, Type="uilistbox").Value), "section1/SVD");
verifyEqual(testCase, axesHandle.XLim, [1, 4], AbsTol=1e-12);
verifyEqual(testCase, axesHandle.YLim, [2, 7], AbsTol=1e-12);
verifyEqual(testCase, stored.Configuration.ComparisonKeys, "section1/SVD");
files = dir(fullfile(testCase.TestData.Root, "**", "analysis.mat"));
verifyEmpty(testCase, files);
verifyEmpty(testCase, dir(fullfile(testCase.TestData.Root, "**", "批处理_*")));
end

function testActualExportButtonOpensAdjustablePreviewAndCancelWritesNoVideo(testCase)
app = openFixture(testCase);
fig = app.getFigure();
setappdata(fig, "PreviewObserved", false);
poller = timer(ExecutionMode="fixedSpacing", Period=0.2, StartDelay=0.2, ...
    TimerFcn=@(~, ~)cancelReadyPreview(fig));
timerCleanup = onCleanup(@()deletePreviewTimer(poller));
start(poller);
buttons = findall(fig, Type="uibutton");
button = buttons(arrayfun(@(item)string(item.Text) == "导出汇报视频", buttons));
button.ButtonPushedFcn(button, []);
verifyTrue(testCase, getappdata(fig, "PreviewObserved"));
verifyEmpty(testCase, dir(fullfile(testCase.TestData.Root, "**", "*.mp4")));
verifyEmpty(testCase, findall(groot, Tag="fUSExportPreview"));
clear timerCleanup
end

function cancelReadyPreview(owner)
windows = findall(groot, Tag="fUSExportPreview");
if isempty(windows)
    return
end
fig = windows(1);
buttons = findall(fig, Type="uibutton");
confirm = buttons(arrayfun(@(item)startsWith(string(item.Text), "确认布局"), buttons));
if isempty(confirm) || confirm.Enable == "off"
    return
end
setappdata(owner, "PreviewObserved", true);
layout = findall(fig, Tag="ExportPreviewLayout");
layout.Value = "right";
layout.ValueChangedFcn(layout, []);
fig.CloseRequestFcn(fig, []);
end

function deletePreviewTimer(poller)
if isvalid(poller)
    stop(poller);
    delete(poller);
end
end

function app = openFixture(testCase)
app = fUSWorkspaceAppV2(testCase.TestData.Root, RestoreLastProject=false);
testCase.addTeardown(@()deleteApp(app));
app.getFigure().Visible = "off";
end

function curves = fullCurves(figureHandle)
lines = findall(figureHandle, Type="line");
curves = lines(arrayfun(@(item)(isnumeric(item.UserData) && isscalar(item.UserData)) ...
    || (isstruct(item.UserData) && isfield(item.UserData, "SectionKey") ...
        && isfield(item.UserData, "ROIIndex")), lines));
end

function result = tableWithColumns(figureHandle, names)
tables = findall(figureHandle, Type="uitable");
result = tables(arrayfun(@(item)istable(item.Data) ...
    && all(ismember(names, string(item.Data.Properties.VariableNames))), tables));
assert(isscalar(result), "未找到预期数据表。");
end

function result = sectionDropdown(figureHandle)
dropdowns = findall(figureHandle, Type="uidropdown");
result = dropdowns(arrayfun(@(item)any(string(item.ItemsData) == "section1/SVD"), dropdowns));
assert(isscalar(result), "未找到截面切换控件。");
end

function result = viewDropdown(figureHandle)
dropdowns = findall(figureHandle, Type="uidropdown");
result = dropdowns(arrayfun(@(item)any(string(item.ItemsData) == "cbv"), dropdowns));
assert(isscalar(result), "未找到显示模式控件。");
end

function result = checkbox(figureHandle, label)
controls = findall(figureHandle, Type="uicheckbox");
result = controls(arrayfun(@(item)string(item.Text) == label, controls));
assert(isscalar(result), "未找到勾选控件。");
end

function switchSection(control, key)
control.Value = key;
control.ValueChangedFcn(control, struct(Value=key));
drawnow;
end

function saveProject(figureHandle)
buttons = findall(figureHandle, Type="uibutton");
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
