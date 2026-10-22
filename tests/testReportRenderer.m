function tests = testReportRenderer
%TESTREPORTRENDERER 科研汇报帧的时间同步、轮廓和实际视频解码。
tests = functiontests(localfunctions);
end

function setupOnce(~)
root = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(root, "core"));
end

function testCurrentSamplesAndElapsedPathsFollowPlaybackTime(testCase)
configuration = fixtureConfiguration();
renderer = fus.ReportRenderer(configuration);
cleanup = onCleanup(@()delete(renderer));
images = {repmat(uint8(50), 24, 16, 3), repmat(uint8(100), 24, 16, 3)};
first = renderer.render(images, 0.5);
verifyClass(testCase, first, "uint8");
verifySize(testCase, first, [800, 1280, 3]);
points = findall(renderer.getFigure(), Tag="fUSReportCurrentPoint");
verifyNumElements(testCase, points, 2);
verifyTrue(testCase, all(arrayfun(@(item)item.XData == 0.5, points)));
verifyEqual(testCase, sort(arrayfun(@(item)item.YData, points)), [0; 1]);

second = renderer.render(images, 1.5);
verifyNotEqual(testCase, first, second);
verifyTrue(testCase, all(arrayfun(@(item)item.XData == 1.5, points)));
verifyEqual(testCase, sort(arrayfun(@(item)item.YData, points)), [2; 3]);
elapsed = findall(renderer.getFigure(), Tag="fUSReportElapsed");
verifyTrue(testCase, all(arrayfun(@(item)numel(item.XData) == 3, elapsed)));
cursor = findall(renderer.getFigure(), Tag="fUSReportTime");
verifyEqual(testCase, cursor.Value, 1.5);
clear cleanup
end

function testReportVideoDecodesSafeDimensionsAndKeepsOriginalFrames(testCase)
configuration = fixtureConfiguration();
configuration.FrameSize = [480, 800];
renderer = fus.ReportRenderer(configuration);
rendererCleanup = onCleanup(@()delete(renderer));
images = {repmat(uint8(50), 24, 16, 3), repmat(uint8(100), 24, 16, 3)};
original = images;
output = string(tempname) + ".mp4";
fileCleanup = onCleanup(@()deleteIfPresent(output));
writer = VideoWriter(output, "MPEG-4");
writer.FrameRate = 2;
writer.Quality = 95;
open(writer);
writerCleanup = onCleanup(@()close(writer));
for seconds = [0.5, 1, 1.5]
    writeVideo(writer, renderer.render(images, seconds));
end
clear writerCleanup
reader = VideoReader(output);
verifyEqual(testCase, [reader.Height, reader.Width], [480, 800]);
verifyEqual(testCase, mod([reader.Height, reader.Width], 16), [0, 0]);
count = 0;
while hasFrame(reader)
    decoded = readFrame(reader);
    verifySize(testCase, decoded, [480, 800, 3]);
    count = count+1;
end
verifyEqual(testCase, count, 3);
verifyEqual(testCase, images, original);
clear rendererCleanup fileCleanup
end

function testRejectsUnsynchronizedCurveInputAndSupportsEmptyCurves(testCase)
configuration = fixtureConfiguration();
configuration.Curves(1).Times = [0.5; 0.5; 1.5];
verifyError(testCase, @()fus.ReportRenderer(configuration), "fUS:ReportCurve");

configuration = struct(ImageTitles="Single image", ShowColorbar=false, ...
    FrameSize=[241, 481]);
renderer = fus.ReportRenderer(configuration);
cleanup = onCleanup(@()delete(renderer));
frame = renderer.render({repmat(uint8(80), 24, 16, 3)}, 0.5);
verifySize(testCase, frame, [256, 496, 3]);
verifyEmpty(testCase, findall(renderer.getFigure(), Tag="fUSReportCurrentPoint"));
clear cleanup
end

function testCurveLayoutIsWideByDefaultAndCanBeAdjustedWithoutChangingValues(testCase)
configuration = fixtureConfiguration();
renderer = fus.ReportRenderer(configuration);
cleanup = onCleanup(@()delete(renderer));
curves = findall(renderer.getFigure(), Tag="fUSReportCurves");
position = getpixelposition(curves);
verifyGreaterThan(testCase, position(3)/position(4), 4);
points = findall(renderer.getFigure(), Tag="fUSReportElapsed");
verifyNumElements(testCase, points, 2);
clear cleanup
configuration.Layout = "right";
configuration.CurveFraction = 0.46;
renderer = fus.ReportRenderer(configuration);
cleanup = onCleanup(@()delete(renderer));
curves = findall(renderer.getFigure(), Tag="fUSReportCurves");
verifyEqual(testCase, curves.Position(3), 0.87*0.46, AbsTol=1e-12);
renderer.render({zeros(24, 16, 3, "uint8"), zeros(24, 16, 3, "uint8")}, 1.5);
points = findall(renderer.getFigure(), Tag="fUSReportCurrentPoint");
verifyEqual(testCase, sort([points.YData]), [2, 3]);
clear cleanup
configuration.CurveFraction = 0.05;
verifyError(testCase, @()fus.ReportRenderer(configuration), "fUS:ReportLayout");
end

function configuration = fixtureConfiguration()
curves = [struct(Name="Section 1 · Left", Times=[0.5; 1; 1.5], ...
    Values=[0; 1; 3], Color=[0.2, 0.7, 1]), ...
    struct(Name="Section 2 · Right", Times=[0.5; 1; 1.5], ...
    Values=[1; 2; 2], Color=[1, 0.6, 0.2])];
plan = table([0; 0.75], [0.75; 1.5], ["静息"; "刺激"], ...
    VariableNames=["Start_s", "End_s", "Label"]);
roi = struct(Name="Left", NormalizedPosition=[0.1, 0.1; 0.45, 0.1; ...
    0.45, 0.6; 0.1, 0.6], Visible=true);
configuration = struct(ImageTitles=["Section 1", "Section 2"], ...
    Curves=curves, ExperimentPlan=plan, DisplayLimit=15, Unit="%ΔPD", ...
    ROIs={{roi, struct([])}}, MaskVertices={{[], [0, 0; 1, 0; 1, 1; 0, 1]}});
end

function deleteIfPresent(path)
if isfile(path)
    delete(path);
end
end
