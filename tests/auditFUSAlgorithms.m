function findings = auditFUSAlgorithms()
%AUDITFUSALGORITHMS Reproduce numerical audit observations without the GUI.
% These assertions document existing behavior, not desired regression targets.
% Synthetic images are created only in a new temporary directory.
projectFolder = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(projectFolder, 'core'));
folder = string(tempname);
mkdir(folder);
cleanup = onCleanup(@()rmdir(folder, 's'));
p = fus.CBVEngine.defaultParameters();
p.SpatialAveragePixels = 1;
p.TemporalAverageFrames = 1;
p.MinimumBaselineGray = 0;
p.ConversionMode = "linear";
findings = struct();

sequence = makeSequence(folder, 'uint16', ...
    {uint16(1000*ones(8,6)), uint16(1100*ones(8,6))}, ...
    ["frames_1_500.png", "frames_501_1000.png"]);
b = fus.CBVEngine.computeBaseline(sequence, [0,0.5], 2, p);
m = fus.CBVEngine.calculateMap(sequence, b, 2, p);
g1 = sequence.readGray(1); g2 = sequence.readGray(2);
findings.Uint16 = struct(Input=[1000,1100], Read=[g1(1),g2(1)], ...
    ExpectedPercent=10, ActualPercent=m(1));
assert(m(1) == 0 && g1(1) == 4 && g2(1) == 4);

sequence = makeSequence(folder, 'zero', ...
    {uint8(zeros(8,6)), uint8(10*ones(8,6))}, ...
    ["frames_1_500.bmp", "frames_501_1000.bmp"]);
b = fus.CBVEngine.computeBaseline(sequence, [0,0.5], 2, p);
m = fus.CBVEngine.calculateMap(sequence, b, 2, p);
findings.ZeroBaseline = struct(ActualPercent=m(1), ...
    IncludedWhenMinimumIsZero=b.AnalysisMask(4,3));
assert(isfinite(m(1)) && m(1) > 1e18 && b.AnalysisMask(4,3));

sequence = makeSequence(folder, 'mismatch', ...
    {uint8(100*ones(8,6)), uint8(100*ones(8,6))}, ...
    ["frames_1_500.bmp", "frames_501_1000.bmp"]);
b = fus.CBVEngine.computeBaseline(sequence, [0,0.5], 2, p);
q = p; q.ConversionMode = "log10Scaled"; q.Log10PerGray = 0.01;
m = fus.CBVEngine.calculateMap(sequence, b, 2, q);
findings.ParameterMismatch = struct(IdenticalInputsActualPercent=m(1));
assert(abs(m(1)+90) < 1e-10);

sequence = makeSequence(folder, 'gap', ...
    {uint8(100*ones(8,6)), uint8(200*ones(8,6))}, ...
    ["frames_1_500.bmp", "frames_1001_1500.bmp"]);
b = fus.CBVEngine.computeBaseline(sequence, [0,1], 2, p);
findings.Gap = struct(FrameEnds=sequence.FrameEnds', ...
    TimeByOrdinal=(1:2)/2, TimeAtRawFPS1000=sequence.FrameEnds'/1000, ...
    BaselineIndices=b.Indices, BaselineValue=b.Signal(1));
assert(isequal(b.Indices, [1,2]) && b.Signal(1) == 150);

sequence = makeSequence(folder, 'duplicate', ...
    {uint8(100*ones(8,6)), uint8(100*ones(8,6))}, ...
    ["frames_1_500.bmp", "frames_1_500.png"]);
findings.Duplicate = struct(Count=sequence.frameCount(), FrameEnds=sequence.FrameEnds');
assert(sequence.frameCount() == 2);

sequence = makeSequence(folder, 'fallback', ...
    {uint8(20*ones(8,6)), uint8(10*ones(8,6))}, ["z.bmp", "a.png"]);
[~, names, extensions] = fileparts(sequence.Files);
findings.FallbackSort = names + extensions;
assert(isequal(findings.FallbackSort, ["z.bmp";"a.png"]));

rgb1 = repmat(uint8(100*ones(8,6)), 1,1,3);
rgb2 = rgb1; rgb2(:,:,2) = 200;
sequence = makeSequence(folder, 'rgb', {rgb1,rgb2}, ...
    ["frames_1_500.png", "frames_501_1000.png"]);
b = fus.CBVEngine.computeBaseline(sequence, [0,0.5], 2, p);
m = fus.CBVEngine.calculateMap(sequence, b, 2, p);
findings.RGB = struct(GreenChannel=[100,200], ActualPercent=m(1));
assert(m(1) == 0);

images = cell(1,12); names = strings(1,12);
for k = 1:12
    images{k} = uint8((100+100*(k>=7))*ones(8,6));
    names(k) = sprintf('frames_%d_%d.bmp',(k-1)*500+1,k*500);
end
sequence = makeSequence(folder, 'step', images, names);
b = fus.CBVEngine.computeBaseline(sequence, [0,1], 2, p);
q = p; q.TemporalAverageFrames = 5;
[m, indices] = fus.CBVEngine.calculateMap(sequence, b, 5, q);
edgeIndices = fus.CBVEngine.temporalWindow(1,5,12);
findings.Temporal = struct(FirstChangedSourceTime=7/2, ...
    EarlierOutputTime=5/2, EarlierPercent=m(1), Indices=indices, ...
    EdgeLabelTime=1/2, EdgeMeanTimestamp=mean(edgeIndices)/2);
assert(m(1) == 20 && isequal(indices,3:7));
findings.InvalidCenter = fus.CBVEngine.temporalWindow(-10,5,12);
assert(isequal(findings.InvalidCenter,1:5));

sequence = makeSequence(folder, 'log', ...
    {uint8(zeros(8,6)), uint8(100*ones(8,6)), uint8(100*ones(8,6))}, ...
    ["frames_1_500.bmp", "frames_501_1000.bmp", "frames_1001_1500.bmp"]);
q = p; q.ConversionMode = "log10Scaled"; q.Log10PerGray = 0.01;
b = fus.CBVEngine.computeBaseline(sequence, [0,1], 2, q);
m = fus.CBVEngine.calculateMap(sequence, b, 3, q);
findings.LogCorrectOrder = struct(Baseline=b.Signal(1), ActualPercent=m(1));
assert(abs(b.Signal(1)-5.5) < 1e-10 && abs(m(1)-100*4.5/5.5) < 1e-10);
q.ConversionMode = "dB8bit"; q.DynamicRangeDb = 25.5;
b = fus.CBVEngine.computeBaseline(sequence, [0,1], 2, q);
m = fus.CBVEngine.calculateMap(sequence, b, 3, q);
findings.DbCorrectOrder = struct(Baseline=b.Signal(1), ActualPercent=m(1));
assert(abs(b.Signal(1)-5.5) < 1e-10 && abs(m(1)-100*4.5/5.5) < 1e-10);

q.ConversionMode = "log10Scaled"; q.Log10PerGray = -0.01;
b = fus.CBVEngine.computeBaseline(sequence, [0,0.5], 2, q);
m = fus.CBVEngine.calculateMap(sequence, b, 3, q);
findings.NegativeScaleAccepted = m(1);
assert(abs(m(1)+90) < 1e-10);

plan = table([0;5], [10;15], ["rest";"stim"], ...
    VariableNames=["Start_s","End_s","Label"]);
findings.OverlappingPhase = fus.ExperimentPlan.phaseAt(plan,7);
assert(findings.OverlappingPhase == "rest");

% A pure one-pixel translation produces a response despite constant vessel signal.
still = uint8(10*ones(8,8)); still(:,4) = 100;
moved = uint8(10*ones(8,8)); moved(:,5) = 100;
sequence = makeSequence(folder, 'motion', {still,moved}, ...
    ["frames_1_500.bmp", "frames_501_1000.bmp"]);
b = fus.CBVEngine.computeBaseline(sequence, [0,0.5], 2, p);
m = fus.CBVEngine.calculateMap(sequence, b, 2, p);
findings.Motion = struct(OldVesselPercent=m(4,4), NewVesselPercent=m(4,5));
assert(m(4,4) == -90 && m(4,5) == 900);

fprintf('%s\n', jsonencode(findings, PrettyPrint=true));
fprintf('All 14 audit observations reproduced. These are NOT 14 algorithm correctness tests.\n');
clear cleanup
end

function sequence = makeSequence(rootFolder, subfolder, images, names)
folder = fullfile(rootFolder, subfolder);
mkdir(folder);
for k = 1:numel(images)
    imwrite(images{k}, fullfile(folder,names(k)));
end
sequence = fus.ImageSequence(folder);
end
