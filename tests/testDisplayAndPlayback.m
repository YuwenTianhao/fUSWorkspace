function tests = testDisplayAndPlayback
%TESTDISPLAYANDPLAYBACK 显示区域不影响定量结果，播放点与曲线样本一致。
tests = functiontests(localfunctions);
end

function setupOnce(~)
root = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(root, "app"), fullfile(root, "core"));
end

function testManualMaskAffectsOnlyOverlayAndRejectsNonfiniteSamples(testCase)
map = [10, -10, NaN; 0, 5, Inf];
original = map;
manual = logical([1, 0, 1; 1, 1, 1]);
display = struct(LowThreshold=0, HighThreshold=10, Transparency=0.8, ...
    ShowBackground=true, BrainMask=true, ApplyUserMask=true, ...
    UserMask=manual, ValidSignalMask=true(2, 3));
mask = fus.FrameRenderer.visibleMask(map, false(2, 3), display);
verifyEqual(testCase, mask, logical([1, 0, 0; 0, 1, 0]));
verifyEqual(testCase, map, original);
finiteMap = [10, -10, 2; 0, 5, -3];
background = fus.FrameRenderer.baselineBackground([10, 20, 30; 10, 20, 30], true);
frame = fus.FrameRenderer.renderCBV(finiteMap, ...
    [10, 20, 30; 10, 20, 30], false(2, 3), display);
verifyEqual(testCase, frame(1, 2, :), background(1, 2, :));
verifyNotEqual(testCase, frame(1, 1, :), background(1, 1, :));
display.BrainMask = false;
unrestricted = fus.FrameRenderer.visibleMask(finiteMap, false(2, 3), display);
verifyTrue(testCase, unrestricted(1, 2));
end

function testScientificDivergingColorMapHasBlueNegativeAndRedPositive(testCase)
colors = fus.FrameRenderer.blueWhiteRed(257);
verifySize(testCase, colors, [257, 3]);
verifyGreaterThan(testCase, colors(1, 3), colors(1, 1));
verifyGreaterThan(testCase, colors(end, 1), colors(end, 3));
verifyEqual(testCase, colors(129, :), [247, 247, 247]/255, AbsTol=1e-12);
end

function testROIsAreOutlineOnlyAndPlaybackPointsTrackTime(testCase)
folder = string(tempname);
mkdir(folder);
folderCleanup = onCleanup(@()rmdir(folder, "s"));
for index = 1:3
    imwrite(uint8([10*index*ones(8, 3), 20*index*ones(8, 3)]), ...
        fullfile(folder, sprintf("frames_%d_%d.bmp", 500*(index-1)+1, 500*index)));
end
project = fus.ExperimentStore.newProject(folder);
project.Configuration = struct(ActualFPS=2, PlaybackFPS=10, ...
    BaselineStart=0, BaselineEnd=0.5, SpatialAverage=1, TemporalAverage=1, ...
    MinimumBaselineGray=0, ConversionMode="linear", BrainMask=true);
project.ExperimentPlan = table(0, 1.5, "baseline", ...
    VariableNames=["Start_s", "End_s", "Label"]);
left = [0, 0; 0.4, 0; 0.4, 1; 0, 1];
right = [0.6, 0; 1, 0; 1, 1; 0.6, 1];
rois = [makeROI("Left", left), makeROI("Right", right)];
parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.MinimumBaselineGray = 0;
parameters.ConversionMode = "linear";
state = struct(Configuration=struct(Width=6, Height=8, LockRatio=false, BrainMask=true), ...
    CurrentIndex=1, ROIs=rois, ROISelectedIndex=1, ...
    ROICurveTimes=(1:3)'/2, ROICurveValues=[0, 0; 100, 100; 200, 200], ...
    ROICurveValid=[true, true], ROICurveParameters=parameters, ROICurveFPS=2, ...
    Fingerprint=fus.ExperimentStore.fingerprint(folder, "image"), ...
    AnalysisSignature=struct(Parameters=parameters, ActualFPS=2, BaselineSeconds=[0, 0.5]), ...
    UserDisplayMask=rois(1).Mask, UserDisplayMaskVertices=left);
project = fus.ExperimentStore.putState(project, ".", state);
project.LastSectionKey = ".";
fus.ExperimentStore.save(folder, project);
hadPreference = ispref("fUSWorkspace", "LastExperimentRoot");
oldPreference = getpref("fUSWorkspace", "LastExperimentRoot", "");
preferenceCleanup = onCleanup(@()restorePreference(hadPreference, oldPreference));
app = fUSWorkspaceAppV2(folder, RestoreLastProject=false);
appCleanup = onCleanup(@()delete(app));
figureHandle = app.getFigure();
figureHandle.Visible = "off";
polygons = findall(figureHandle, Type="images.roi.Polygon");
verifyTrue(testCase, all(arrayfun(@(item)item.FaceAlpha == 0, polygons)));
curves = findall(figureHandle, Type="line");
curves = curves(arrayfun(@(item)isnumeric(item.UserData) && isscalar(item.UserData), curves));
verifyNumElements(testCase, curves, 2);
curves(1).ButtonDownFcn(curves(1), struct(IntersectionPoint=[1.5, 200, 0]));
points = findall(figureHandle, Tag="fUSCurrentPoint");
verifyNumElements(testCase, points, 2);
verifyEqual(testCase, [points.XData], [1.5, 1.5], AbsTol=1e-12);
verifyEqual(testCase, [points.YData], [200, 200], AbsTol=1e-12);
paths = findall(figureHandle, Tag="fUSCurvePast");
verifyTrue(testCase, all(arrayfun(@(item)numel(item.XData) == 3, paths)));
dropdowns = findall(figureHandle, Type="uidropdown");
view = dropdowns(arrayfun(@(item)any(string(item.ItemsData) == "cbv"), dropdowns));
verifyNumElements(testCase, view, 1);
view.Value = "cbv";
view.ValueChangedFcn(view, struct(Value="cbv"));
images = findall(figureHandle, Type="image");
activity = images(arrayfun(@(item)isequal(size(item.CData), [8, 6]), images));
verifyNumElements(testCase, activity, 1);
verifyGreaterThan(testCase, max(activity.AlphaData(:, 1:2), [], "all"), 0);
verifyEqual(testCase, activity.AlphaData(:, 4:6), zeros(8, 3));
verifyEqual(testCase, curves(1).YData, [0, 100, 200]);
clear appCleanup preferenceCleanup folderCleanup
end

function roi = makeROI(name, vertices)
roi = struct(Name=char(name), Mask=fus.ROIEngine.polygonMask(vertices, [8, 6], [1, 1]), ...
    NormalizedPosition=vertices, Visible=true);
end

function restorePreference(hadPreference, previous)
if hadPreference
    setpref("fUSWorkspace", "LastExperimentRoot", previous);
elseif ispref("fUSWorkspace", "LastExperimentRoot")
    rmpref("fUSWorkspace", "LastExperimentRoot");
end
end
