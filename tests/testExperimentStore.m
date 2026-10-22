function tests = testExperimentStore
%TESTEXPERIMENTSTORE 跨截面参数共享、项目恢复和数据目录发现的回归测试。
tests = functiontests(localfunctions);
end

function setupOnce(~)
root = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(root, "core"));
end

function testDiscoversDirectSequencesWithoutDuplicateSVDAndSortsNaturally(testCase)
root = string(tempname);
mkdir(root);
cleanup = onCleanup(@()rmdir(root, "s"));
folders = [fullfile(root, "section10", "SVD"), ...
    fullfile(root, "section2", "SVD"), ...
    fullfile(root, "results"), fullfile(root, ".hidden")];
for folder = folders
    mkdir(folder);
    imwrite(uint8(ones(3)), fullfile(folder, "frame.png"));
end
sections = fus.ExperimentStore.discover(root);
verifyEqual(testCase, string({sections.Key}), ["section2/SVD", "section10/SVD"]);
verifyEqual(testCase, string({sections.DataSourceType}), ["image", "image"]);
clear cleanup
end

function testPrioritizesPDIButKeepsDistinctChildSequences(testCase)
root = string(tempname);
mkdir(root);
cleanup = onCleanup(@()rmdir(root, "s"));
imwrite(uint8(ones(3)), fullfile(root, "preview.png"));
file = fopen(fullfile(root, "data.pdi"), "w");
fclose(file);
mkdir(fullfile(root, "other"));
imwrite(uint8(ones(3)), fullfile(root, "other", "frame.bmp"));
sections = fus.ExperimentStore.discover(root);
verifyEqual(testCase, string({sections.Key}), [".", "other"]);
verifyEqual(testCase, string({sections.DataSourceType}), ["pdi", "image"]);
clear cleanup
end

function testOverviewImagesDoNotDuplicateCanonicalSVDSources(testCase)
root = string(tempname);
mkdir(root);
cleanup = onCleanup(@()rmdir(root, "s"));
for folder = [root, fullfile(root, "section1")]
    mkdir(fullfile(folder, "SVD"));
    imwrite(uint8(ones(3)), fullfile(folder, "overview.png"));
    imwrite(uint8(2*ones(3)), fullfile(folder, "SVD", "frames_1_500.bmp"));
end
sections = fus.ExperimentStore.discover(root);
verifyEqual(testCase, sort(string({sections.Key})), sort(["SVD", "section1/SVD"]));
resolvedFolders = strings(1, numel(sections));
for index = 1:numel(sections)
    sequence = fus.ImageSequence(sections(index).DataFolder);
    resolvedFolders(index) = sequence.Folder;
    verifyEqual(testCase, sequence.frameCount(), 1);
    verifyEqual(testCase, sequence.readGray(1), 2*ones(3));
end
verifyEqual(testCase, numel(unique(resolvedFolders)), 2);
clear cleanup
end

function testCustomResultDirectoryIsExcludedButRootCannotBeExcluded(testCase)
root = string(tempname);
mkdir(root);
cleanup = onCleanup(@()rmdir(root, "s"));
mkdir(fullfile(root, "section1", "SVD"));
mkdir(fullfile(root, "my-chosen-results", "section1"));
imwrite(uint8(ones(3)), fullfile(root, "section1", "SVD", "frames_1_500.bmp"));
imwrite(uint8(ones(3)), fullfile(root, "my-chosen-results", "section1", "CBV.png"));
sections = fus.ExperimentStore.discover(root, ...
    ExcludedFolders=fullfile(root, "my-chosen-results"));
verifyEqual(testCase, string({sections.Key}), "section1/SVD");
sections = fus.ExperimentStore.discover(root, ExcludedFolders=root);
verifyEqual(testCase, numel(sections), 2);
sections = fus.ExperimentStore.discover(root, ExcludedFolders="my-chosen-results");
verifyEqual(testCase, string({sections.Key}), "section1/SVD");
clear cleanup
end

function testSharedParametersAndSeparateSectionStatesRoundTrip(testCase)
root = string(tempname);
mkdir(root);
cleanup = onCleanup(@()rmdir(root, "s"));
for section = ["a", "b"]
    mkdir(fullfile(root, section));
    imwrite(uint8(ones(3)), fullfile(root, section, "frame.png"));
end
project = fus.ExperimentStore.newProject(root);
project.Configuration = struct(ActualFPS=2, BaselineEnd=60, Width=123, ...
    Height=321, LockRatio=true, DataSourceType="image");
project.ExperimentPlan = fus.ExperimentPlan.defaultPlan();
project.LastSectionKey = "b";
stateA = struct(CurrentIndex=2, ROIs=struct(Name="left"), ROICurveValues=[1; 2]);
stateB = struct(CurrentIndex=3, ROIs=struct(Name="right"), ROICurveValues=[4; 5]);
project = fus.ExperimentStore.putState(project, "a", stateA);
project = fus.ExperimentStore.putState(project, "b", stateB);
fus.ExperimentStore.save(root, project);
restored = fus.ExperimentStore.load(root);
verifyEqual(testCase, restored.Configuration, struct(ActualFPS=2, BaselineEnd=60));
verifyEqual(testCase, restored.LastSectionKey, "b");
verifyEqual(testCase, fus.ExperimentStore.getState(restored, "a"), stateA);
verifyEqual(testCase, fus.ExperimentStore.getState(restored, "b"), stateB);
verifyEqual(testCase, restored.ExperimentPlan, project.ExperimentPlan);
verifyNotEmpty(testCase, restored.SavedAt);
clear cleanup
end

function testBackupKeepsPreviousRevisionAndRelocationRebasesData(testCase)
root = string(tempname);
mkdir(root);
relocated = string(tempname);
cleanup = onCleanup(@()removeFolders([root, relocated]));
imwrite(uint8(ones(3)), fullfile(root, "frame.png"));
project = fus.ExperimentStore.newProject(root);
project.Configuration = struct(ActualFPS=2);
fus.ExperimentStore.save(root, project);
project.Configuration.ActualFPS = 4;
fus.ExperimentStore.save(root, project);
backup = load(fus.ExperimentStore.projectPath(root) + ".bak", "project", "-mat");
verifyEqual(testCase, backup.project.Configuration.ActualFPS, 2);
copyfile(root, relocated);
restored = fus.ExperimentStore.load(relocated);
verifyEqual(testCase, restored.RootFolder, relocated);
verifyEqual(testCase, restored.Sections(1).DataFolder, relocated);
verifyEqual(testCase, restored.Configuration.ActualFPS, 4);
clear cleanup
end

function testMissingProjectAndUnknownStateAreEmpty(testCase)
root = string(tempname);
mkdir(root);
cleanup = onCleanup(@()rmdir(root, "s"));
verifyEmpty(testCase, fus.ExperimentStore.load(root));
project = fus.ExperimentStore.newProject(root);
verifyEmpty(testCase, fus.ExperimentStore.getState(project, "missing"));
verifyError(testCase, @()fus.ExperimentStore.putState(project, "missing", struct()), ...
    "fUS:UnknownSection");
clear cleanup
end

function testExplicitBackupLoadReadsSelectedRevisionWithoutChangingFiles(testCase)
root = string(tempname);
mkdir(root);
cleanup = onCleanup(@()rmdir(root, "s"));
project = fus.ExperimentStore.newProject(root);
project.Configuration = struct(ActualFPS=2);
fus.ExperimentStore.save(root, project);
project.Configuration.ActualFPS = 4;
fus.ExperimentStore.save(root, project);
primary = fus.ExperimentStore.projectPath(root);
backupPath = primary + ".bak";
beforeBackup = dir(backupPath);
file = fopen(primary, "w");
fwrite(file, 'corrupt primary fixture');
fclose(file);
recovered = fus.ExperimentStore.load(root, SourceFile=backupPath);
verifyEqual(testCase, recovered.Configuration.ActualFPS, 2);
verifyEqual(testCase, string(fileread(primary)), "corrupt primary fixture");
afterBackup = dir(backupPath);
verifyEqual(testCase, afterBackup.bytes, beforeBackup.bytes);
verifyEqual(testCase, afterBackup.datenum, beforeBackup.datenum);
verifyError(testCase, @()fus.ExperimentStore.load(root, SourceFile=primary + ".missing"), ...
    "fUS:ProjectSourceNotFound");
clear cleanup
end

function testResultPathsStayPortableInsideExperiment(testCase)
root = string(tempname);
inside = fullfile(root, "fUS分析项目", "results", "section1");
portable = fus.ExperimentStore.portablePath(root, inside);
verifyEqual(testCase, portable, "fUS分析项目/results/section1");
verifyEqual(testCase, fus.ExperimentStore.resolvePath(root, portable), inside);
verifyEqual(testCase, fus.ExperimentStore.portablePath(root, root), ".");
outside = fullfile(tempdir, "external-results");
verifyEqual(testCase, fus.ExperimentStore.portablePath(root, outside), string(outside));
verifyError(testCase, @()fus.ExperimentStore.resolvePath(root, "../other"), ...
    "fUS:InvalidProjectPath");
end

function testFileFingerprintDetectsReplacement(testCase)
root = string(tempname);
mkdir(root);
cleanup = onCleanup(@()rmdir(root, "s"));
imwrite(uint8(ones(3)), fullfile(root, "frame.png"));
first = fus.ExperimentStore.fingerprint(root, "image");
verifyEqual(testCase, first.Count, 1);
verifyEqual(testCase, first.Names, "frame.png");
imwrite(uint8(ones(4)), fullfile(root, "extra.png"));
second = fus.ExperimentStore.fingerprint(root, "image");
verifyEqual(testCase, second.Count, 2);
verifyNotEqual(testCase, first, second);
clear cleanup
end

function testPlanRejectsNegativeAndOverlappingTimesButAcceptsAdjacentPhases(testCase)
negative = table(-1, 2, "negative", VariableNames=["Start_s", "End_s", "Label"]);
verifyError(testCase, @()fus.ExperimentPlan.normalize(negative), "fUS:InvalidExperimentPlan");
overlap = table([0; 5], [10; 15], ["a"; "b"], ...
    VariableNames=["Start_s", "End_s", "Label"]);
verifyError(testCase, @()fus.ExperimentPlan.normalize(overlap), "fUS:OverlappingExperimentPlan");
adjacent = table([5; 0], [10; 5], ["b"; "a"], ...
    VariableNames=["Start_s", "End_s", "Label"]);
normalized = fus.ExperimentPlan.normalize(adjacent);
verifyEqual(testCase, normalized.Start_s, [0; 5]);
verifyEqual(testCase, fus.ExperimentPlan.phaseAt(normalized, 5), "b");
end

function removeFolders(folders)
for folder = folders
    if isfolder(folder)
        rmdir(folder, "s");
    end
end
end
