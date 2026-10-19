function tests = testCoreAlgorithms
%TESTCOREALGORITHMS 核心模块的回归测试，不启动 App 界面。
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
projectFolder = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(projectFolder, "core"));
testCase.TestData.ProjectFolder = projectFolder;
end

function testImageSequenceSortsByRawFrameNumber(testCase)
folder = createSequence([30, 10, 20], ...
    ["frames_1001_1500.bmp", "frames_1_500.bmp", "frames_501_1000.bmp"]);
cleanup = onCleanup(@()rmdir(folder, "s"));
sequence = fus.ImageSequence(folder);

verifyEqual(testCase, sequence.FrameStarts', [1, 501, 1001]);
verifyEqual(testCase, squeeze(sequence.readGray(1)), 10*ones(8, 6));
clear cleanup
end

function testUnknownLogModeReturnsGrayDifference(testCase)
folder = createSequence([10, 10, 20, 20], defaultNames(4));
cleanup = onCleanup(@()rmdir(folder, "s"));
sequence = fus.ImageSequence(folder);
parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.MinimumBaselineGray = 0;

baseline = fus.CBVEngine.computeBaseline(sequence, [0, 1], 2, parameters);
[map, indices] = fus.CBVEngine.calculateMap(sequence, baseline, 3, parameters);

verifyEqual(testCase, baseline.Indices, 1:2);
verifyEqual(testCase, indices, 3);
verifyEqual(testCase, map, 10*ones(8, 6), AbsTol=1e-12);
clear cleanup
end

function testLinearModeReturnsPercentChange(testCase)
folder = createSequence([10, 10, 20], defaultNames(3));
cleanup = onCleanup(@()rmdir(folder, "s"));
sequence = fus.ImageSequence(folder);
parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.MinimumBaselineGray = 0;
parameters.ConversionMode = "linear";

baseline = fus.CBVEngine.computeBaseline(sequence, [0, 1], 2, parameters);
map = fus.CBVEngine.calculateMap(sequence, baseline, 3, parameters);

verifyEqual(testCase, map, 100*ones(8, 6), AbsTol=1e-12);
clear cleanup
end

function testMultipleROICurvesUseCBVMapsAndFrameTimes(testCase)
folder = string(tempname);
mkdir(folder);
cleanup = onCleanup(@()rmdir(folder, "s"));
names = defaultNames(3);
for index = 1:3
    frame = uint8([10*ones(4, 2), (10*index)*ones(4, 2)]);
    imwrite(frame, fullfile(folder, names(index)));
end

sequence = fus.ImageSequence(folder);
parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.MinimumBaselineGray = 0;
parameters.ConversionMode = "linear";
baseline = fus.CBVEngine.computeBaseline(sequence, [0, 0.5], 2, parameters);
left = logical([ones(4, 2), zeros(4, 2)]);
right = ~left;
[times, curves] = fus.CBVEngine.calculateROICurves( ...
    sequence, baseline, {left, right}, parameters, 2);
verifyEqual(testCase, times, [0.5; 1; 1.5]);
verifyEqual(testCase, curves, [0, 0; 0, 100; 0, 200], AbsTol=1e-12);
verifyError(testCase, @()fus.CBVEngine.calculateROICurves( ...
    sequence, baseline, {false(4, 4)}, parameters, 2), "fUS:InvalidROI");
clear cleanup
end

function testFastROICurvesMatchMapAveragesWithTemporalAndSpatialFiltering(testCase)
folder = string(tempname);
mkdir(folder);
cleanup = onCleanup(@()rmdir(folder, "s"));
names = defaultNames(7);
[x, y] = meshgrid(1:6, 1:8);
for index = 1:7
    frame = uint8(20 + 2*x + 3*y + index*(x + mod(y, 3)));
    imwrite(frame, fullfile(folder, names(index)));
end
sequence = fus.ImageSequence(folder);
left = x <= 3;
middle = y >= 3 & y <= 6;
masks = {left, middle};
for mode = ["unknown", "linear", "dB8bit"]
    parameters = fus.CBVEngine.defaultParameters();
    parameters.ConversionMode = mode;
    parameters.SpatialAveragePixels = 3;
    parameters.TemporalAverageFrames = 4;
    parameters.MinimumBaselineGray = 0;
    baseline = fus.CBVEngine.computeBaseline(sequence, [0, 1], 2, parameters);
    [~, fastCurves] = fus.CBVEngine.calculateROICurves( ...
        sequence, baseline, masks, parameters, 2);
    reference = zeros(7, numel(masks));
    for frameIndex = 1:7
        map = fus.CBVEngine.calculateMap( ...
            sequence, baseline, frameIndex, parameters);
        for roiIndex = 1:numel(masks)
            reference(frameIndex, roiIndex) = mean(map(masks{roiIndex}));
        end
    end
    verifyEqual(testCase, fastCurves, reference, AbsTol=1e-9);
end
clear cleanup
end

function testPolygonMaskTracksDisplayedImageCoordinates(testCase)
vertices = [0, 0; 20, 0; 20, 40; 0, 40];
mask = fus.ROIEngine.polygonMask(vertices, [4, 4], [40, 40]);
verifyEqual(testCase, mask, logical([ones(4, 2), zeros(4, 2)]));
resizedMask = fus.ROIEngine.polygonMask(vertices/2, [4, 4], [20, 20]);
verifyEqual(testCase, resizedMask, mask);
verifyError(testCase, @()fus.ROIEngine.polygonMask( ...
    [0, 0; 1, 1], [4, 4], [40, 40]), "fUS:InvalidPolygon");
end

function testPDISequenceReadsLinearPayloadAndCalculatesPercent(testCase)
folder = string(tempname);
mkdir(folder);
cleanup = onCleanup(@()rmdir(folder, "s"));
first = single(10*ones(3, 4));
second = single(20*ones(3, 4));
writePDI(fullfile(folder, "SVD_000002_frames_501_1000.pdi"), ...
    2, 501, 1000, second);
writePDI(fullfile(folder, "SVD_000001_frames_1_500.pdi"), ...
    1, 1, 500, first);

sequence = fus.PDISequence(folder);
verifyEqual(testCase, sequence.SourceType, "pdi");
verifyEqual(testCase, sequence.FrameStarts', [1, 501]);
verifyEqual(testCase, sequence.readGray(1), double(first));
verifySize(testCase, sequence.readFrame(1), [3, 4, 3]);

parameters = fus.CBVEngine.defaultParameters();
parameters.SpatialAveragePixels = 1;
parameters.TemporalAverageFrames = 1;
parameters.MinimumBaselineGray = 0;
parameters.ConversionMode = "linear";
baseline = fus.CBVEngine.computeBaseline(sequence, [0, 0.5], 2, parameters);
map = fus.CBVEngine.calculateMap(sequence, baseline, 2, parameters);
verifyEqual(testCase, map, 100*ones(3, 4), AbsTol=1e-12);
[~, roiCurve] = fus.CBVEngine.calculateROICurves( ...
    sequence, baseline, {true(3, 4)}, parameters, 2);
verifyEqual(testCase, roiCurve, [0; 100], AbsTol=1e-12);

parameters.ConversionMode = "unknown";
verifyError(testCase, ...
    @()fus.CBVEngine.calculateMap(sequence, baseline, 2, parameters), ...
    "fUS:PDIRequiresLinearMode");
clear cleanup
end

function testBothImageAndPDISourcesAreDetected(testCase)
folder = string(tempname);
mkdir(folder);
cleanup = onCleanup(@()rmdir(folder, "s"));
imwrite(uint8(ones(3, 4)), fullfile(folder, "frames_1_500.bmp"));
writePDI(fullfile(folder, "frames_1_500.pdi"), 1, 1, 500, ...
    single(ones(3, 4)));
verifyTrue(testCase, fus.ImageSequence.isAvailable(folder));
verifyTrue(testCase, fus.PDISequence.isAvailable(folder));
clear cleanup
end

function testFrameAndWindowTimeDefinitions(testCase)
verifyEqual(testCase, ...
    fus.CBVEngine.secondsToIndices([0, 120], 2, 300), 1:240);
verifyEqual(testCase, fus.CBVEngine.temporalWindow(1, 5, 10), 1:5);
verifyEqual(testCase, fus.CBVEngine.temporalWindow(10, 5, 10), 6:10);
verifyError(testCase, ...
    @()fus.CBVEngine.secondsToIndices([0, 120], 2, 200), ...
    "fUS:BaselineOutsideData");
end

function testExperimentPlanBoundarySemantics(testCase)
plan = fus.ExperimentPlan.defaultPlan();
verifyEqual(testCase, fus.ExperimentPlan.phaseAt(plan, 59.999), "静息baseline");
verifyEqual(testCase, fus.ExperimentPlan.phaseAt(plan, 60), "右后爪夹捏刺激1");
verifyEqual(testCase, fus.ExperimentPlan.phaseAt(plan, 90), "休息1");
verifyEqual(testCase, fus.ExperimentPlan.phaseAt(plan, 150), "右后爪夹捏刺激2");
verifyEqual(testCase, fus.ExperimentPlan.phaseAt(plan, 180), "休息2");
verifyEqual(testCase, fus.ExperimentPlan.phaseAt(plan, 240), "休息2");
verifyEqual(testCase, fus.ExperimentPlan.phaseAt(plan, 240.5), "实验计划结束");
verifyEqual(testCase, fus.ExperimentPlan.phaseAtNormalized(plan, 60), ...
    "右后爪夹捏刺激1");
end

function testRendererUsesThresholdAndMask(testCase)
map = [-10, 10; 2, -2];
baseline = 50*ones(2);
analysisMask = logical([1, 0; 1, 1]);
display = struct(LowThreshold=5, HighThreshold=10, Transparency=1, ...
    ShowBackground=false, BrainMask=true);

mask = fus.FrameRenderer.visibleMask(map, analysisMask, display);
frame = fus.FrameRenderer.renderCBV(map, baseline, analysisMask, display);

verifyEqual(testCase, mask, logical([1, 0; 0, 0]));
verifySize(testCase, frame, [2, 2, 3]);
verifyClass(testCase, frame, "uint8");
end

function testVideoGeometryUsesCodecSafeStride(testCase)
geometry = fus.FrameRenderer.videoGeometry(256/424);
source = uint8(reshape(mod(0:(424*256*3 - 1), 251), 424, 256, 3));
canvas = fus.FrameRenderer.fitToVideoCanvas(source, geometry);

verifyEqual(testCase, ...
    [geometry.ContentHeight, geometry.ContentWidth], [720, 435]);
verifyEqual(testCase, ...
    [geometry.CanvasHeight, geometry.CanvasWidth], [720, 448]);
verifyEqual(testCase, mod(geometry.CanvasHeight, 16), 0);
verifyEqual(testCase, mod(geometry.CanvasWidth, 16), 0);
verifySize(testCase, canvas, [720, 448, 3]);

leftPadding = floor((geometry.CanvasWidth - geometry.ContentWidth)/2);
verifyEqual(testCase, canvas(:, 1:leftPadding, :), ...
    zeros(720, leftPadding, 3, "uint8"));
end

function testVideoWriterRoundTripUsesSafeDimensions(testCase)
geometry = fus.FrameRenderer.videoGeometry(256/424);
source = repmat(uint8(linspace(0, 255, 256)), 424, 1, 3);
expected = fus.FrameRenderer.fitToVideoCanvas(source, geometry);
outputPath = string(tempname) + ".mp4";
cleanup = onCleanup(@()deleteIfPresent(outputPath));

writer = VideoWriter(outputPath, "MPEG-4");
writer.FrameRate = 10;
writer.Quality = 95;
open(writer);
writeVideo(writer, expected);
close(writer);

reader = VideoReader(outputPath);
decoded = readFrame(reader);
verifyEqual(testCase, [reader.Height, reader.Width], [720, 448]);
verifySize(testCase, decoded, [720, 448, 3]);
verifyLessThan(testCase, ...
    mean(abs(double(decoded(:)) - double(expected(:)))), 5);
clear cleanup
end

function folder = createSequence(values, names)
folder = string(tempname);
mkdir(folder);
for index = 1:numel(values)
    image = uint8(values(index)*ones(8, 6));
    imwrite(image, fullfile(folder, names(index)));
end
end

function names = defaultNames(count)
names = strings(1, count);
for index = 1:count
    first = (index - 1)*500 + 1;
    last = index*500;
    names(index) = sprintf("frames_%d_%d.bmp", first, last);
end
end

function deleteIfPresent(path)
if isfile(path)
    delete(path);
end
end


function writePDI(path, sequence, firstFrame, lastFrame, image)
[height, width] = size(image);
fileId = fopen(path, "wb", "ieee-le");
assert(fileId >= 0);
cleanup = onCleanup(@()fclose(fileId));
fwrite(fileId, uint8(char("MRSPDI01")), "uint8");
fwrite(fileId, uint32(1), "uint32");
fwrite(fileId, uint32(160), "uint32");
fwrite(fileId, uint32(width), "uint32");
fwrite(fileId, uint32(height), "uint32");
fwrite(fileId, uint64(sequence), "uint64");
fwrite(fileId, uint32(firstFrame), "uint32");
fwrite(fileId, uint32(lastFrame), "uint32");
fwrite(fileId, uint32(lastFrame-firstFrame+1), "uint32");
fwrite(fileId, uint32(lastFrame-firstFrame+1), "uint32");
fwrite(fileId, uint32(0), "uint32");
fwrite(fileId, uint32(1), "uint32");
fwrite(fileId, [-6.35, 0.05, 3, 0.02, 3, 10], "double");
fwrite(fileId, [50, 20, -6, 56.25], "double");
count = uint64(width*height);
fwrite(fileId, count, "uint64");
fwrite(fileId, 4*count, "uint64");
fwrite(fileId, uint64(0), "uint64");
fwrite(fileId, image, "single");
clear cleanup
end
