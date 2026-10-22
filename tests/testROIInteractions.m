function tests = testROIInteractions
%TESTROIINTERACTIONS 使用临时三帧项目验证实际 UI 回调，不接触实验数据。
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
projectRoot = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(projectRoot, "core"), fullfile(projectRoot, "app"));
end

function testRestoredROIsCanRenameSelectMoveAndSeek(testCase)
folder = string(tempname);
mkdir(folder);
folderCleanup = onCleanup(@()rmdir(folder, "s"));
for index = 1:3
    frame = uint8([10*ones(8, 3), 10*index*ones(8, 3)]);
    imwrite(frame, fullfile(folder, sprintf("frames_%d_%d.bmp", ...
        500*(index-1)+1, 500*index)));
end
project = fus.ExperimentStore.newProject(folder);
project.Configuration = struct(ActualFPS=2, PlaybackFPS=10, ...
    BaselineStart=0, BaselineEnd=0.5, SpatialAverage=1, TemporalAverage=1, ...
    MinimumBaselineGray=0, ConversionMode="linear");
project.ExperimentPlan = table(0, 1.5, "baseline", ...
    VariableNames=["Start_s", "End_s", "Label"]);
leftVertices = [0, 0; 0.4, 0; 0.4, 1; 0, 1];
rightVertices = [0.6, 0; 1, 0; 1, 1; 0.6, 1];
rois = [makeROI("Left", leftVertices), makeROI("Right", rightVertices)];
parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.MinimumBaselineGray = 0;
parameters.ConversionMode = "linear";
state = struct(Configuration=struct(Width=6, Height=8, LockRatio=false), ...
    CurrentIndex=1, ROIs=rois, ROISelectedIndex=1, ...
    Bookmarks=table([], [], strings(0, 1), strings(0, 1), ...
        VariableNames=["Frame", "Time_s", "File", "Note"]), ...
    ROICurveTimes=(1:3)'/2, ROICurveValues=[0, 0; 0, 100; 0, 200], ...
    ROICurveValid=[true, true], ROICurveParameters=parameters, ...
    ROICurveFPS=2, Fingerprint=fus.ExperimentStore.fingerprint(folder, "image"));
state.AnalysisSignature = struct(Parameters=parameters, ...
    ActualFPS=2, BaselineSeconds=[0, 0.5]);
project = fus.ExperimentStore.putState(project, project.Sections(1).Key, state);
project.LastSectionKey = project.Sections(1).Key;
fus.ExperimentStore.save(folder, project);

hadPreference = ispref("fUSWorkspace", "LastExperimentRoot");
oldPreference = getpref("fUSWorkspace", "LastExperimentRoot", "");
preferenceCleanup = onCleanup(@()restorePreference(hadPreference, oldPreference));
app = fUSWorkspaceAppV2(folder, RestoreLastProject=false);
appCleanup = onCleanup(@()delete(app));
figureHandle = app.getFigure();
figureHandle.Visible = "off";
tables = findall(figureHandle, Type="uitable");
roiTable = tables(arrayfun(@(item)isequal(string(item.ColumnName(:))', ...
    ["显示", "ROI", "像素"]), tables));
verifyNumElements(testCase, roiTable, 1);
verifyTrue(testCase, roiTable.ColumnEditable(2));

roiTable.CellEditCallback(roiTable, struct(Indices=[1, 2], NewData="左侧 S1"));
verifyEqual(testCase, string(roiTable.Data.ROI(1)), "左侧 S1");
polygons = findall(figureHandle, Type="images.roi.Polygon");
verifyNumElements(testCase, polygons, 2);
left = polygons(arrayfun(@(item)string(item.Label) == "左侧 S1", polygons));
right = polygons(arrayfun(@(item)string(item.Label) == "Right", polygons));
verifyEqual(testCase, string(left.InteractionsAllowed), "all");

roiTable.CellSelectionCallback(roiTable, struct(Indices=[2, 2]));
verifyTrue(testCase, right.Selected);
verifyFalse(testCase, left.Selected);
curves = findall(figureHandle, Type="line");
curves = curves(arrayfun(@(item)isnumeric(item.UserData) ...
    && isscalar(item.UserData), curves));
rightCurve = curves(arrayfun(@(item)item.UserData == 2, curves));
verifyNumElements(testCase, rightCurve, 1);
verifyGreaterThan(testCase, rightCurve.LineWidth, 3);
notify(left, "ROIClicked");
verifyTrue(testCase, left.Selected);
verifyEqual(testCase, roiTable.Selection, [1, 2]);
verifyLessThan(testCase, rightCurve.LineWidth, 2);
rightCurve.ButtonDownFcn(rightCurve, struct(IntersectionPoint=[1.5, 200, 0]));
cursor = findall(figureHandle, Tag="fUSCurrentTime");
verifyEqual(testCase, cursor.Value, 1.5, AbsTol=1e-12);

oldPixels = roiTable.Data.Pixels(1);
left.Position = [0, 0; 1, 0; 1, 3; 0, 3];
notify(left, "ROIMoved");
verifyNotEqual(testCase, roiTable.Data.Pixels(1), oldPixels);
verifyTrue(testCase, left.Selected);
verifyFalse(testCase, right.Selected);
curves = findall(figureHandle, Type="line");
curves = curves(arrayfun(@(item)isnumeric(item.UserData) ...
    && isscalar(item.UserData), curves));
verifyNumElements(testCase, curves, 1);
verifyEqual(testCase, curves.UserData, 2); % 改变左侧 ROI 不使右侧曲线失效。
clear appCleanup preferenceCleanup folderCleanup
end

function roi = makeROI(name, vertices)
roi = struct(Name=char(name), ...
    Mask=fus.ROIEngine.polygonMask(vertices, [8, 6], [1, 1]), ...
    NormalizedPosition=vertices, Visible=true);
end

function restorePreference(hadPreference, previous)
if hadPreference
    setpref("fUSWorkspace", "LastExperimentRoot", previous);
elseif ispref("fUSWorkspace", "LastExperimentRoot")
    rmpref("fUSWorkspace", "LastExperimentRoot");
end
end
