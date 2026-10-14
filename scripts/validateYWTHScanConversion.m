function report = validateYWTHScanConversion(sourceRoot, outputRoot)
%VALIDATEYWTHSCANCONVERSION Validate converted PDI files against HDF5 source.

arguments
    sourceRoot (1, 1) string = "D:\Tianhao\YWTH_fus4D_20260917"
    outputRoot (1, 1) string = fullfile(sourceRoot, "converted_pdi")
end

projectRoot = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(projectRoot, "core"));

manifest = readtable(fullfile(sourceRoot, "experiment_plans", ...
    "experiment_manifest.csv"), TextType="string");
report = table('Size', [height(manifest), 8], ...
    'VariableTypes', ["double", "string", repmat("double", 1, 6)], ...
    'VariableNames', ["Group", "Condition", "SectionCount", ...
        "PDIFileCount", "FramesPerSection", "ComparedImages", ...
        "MaxAbsoluteError", "TimestampErrors"]);

for row = 1:height(manifest)
    groupNumber = double(manifest.Group(row));
    groupFolder = fullfile(outputRoot, sprintf("group_%02d", groupNumber));
    scanPath = fullfile(sourceRoot, string(manifest.ScanFile(row)));
    sectionManifest = readtable(fullfile(groupFolder, ...
        "section_manifest.csv"), TextType="string");
    timestampTable = readtable(fullfile(groupFolder, ...
        "pose_timestamps.csv"), TextType="string");
    plan = readtable(fullfile(groupFolder, "experiment_plan.csv"), ...
        TextType="string");
    plan = fus.ExperimentPlan.normalize(plan(:, 1:3));

    repeatCount = double(h5read(scanPath, ...
        "/acqMetaData/imgDim/nscanRepeat"));
    sizeX = double(h5read(scanPath, "/acqMetaData/imgDim/sizeX"));
    sizeZ = double(h5read(scanPath, "/acqMetaData/imgDim/sizeZ"));
    poseCount = double(h5read(scanPath, "/acqMetaData/imgDim/npose"));
    planeCount = double(h5read(scanPath, "/acqMetaData/imgDim/sizeY"));
    if height(sectionManifest) ~= poseCount*planeCount ...
            || plan.End_s(end) ~= double(manifest.NominalDuration_s(row))
        error("fUS:ConversionMetadataMismatch", ...
            "Group %d manifest or plan does not match source.", groupNumber);
    end

    scanDateText = string(h5read(scanPath, "/scanMetaData/Date"));
    scanStart = datetime(scanDateText, InputFormat="yyyy-M-d H:m:s", ...
        TimeZone="Asia/Shanghai");
    sampleRepeats = unique([1, ceil(repeatCount/2), repeatCount]);
    comparedImages = 0;
    maximumError = 0;
    timestampErrors = 0;

    for sectionRow = 1:height(sectionManifest)
        pose = double(sectionManifest.Pose(sectionRow));
        plane = double(sectionManifest.Plane(sectionRow));
        sectionFolder = fullfile(groupFolder, ...
            sectionManifest.Folder(sectionRow));
        sequence = fus.PDISequence(sectionFolder, MaxCacheFrames=3);
        if sequence.frameCount() ~= repeatCount ...
                || any(double([sequence.Headers.Version]) ~= 2) ...
                || any(double([sequence.Headers.Width]) ~= sizeX) ...
                || any(double([sequence.Headers.Height]) ~= sizeZ) ...
                || any(double([sequence.Headers.Sequence]) ~= 1:repeatCount)
            error("fUS:ConvertedPDIHeaderMismatch", ...
                "Invalid PDI sequence in %s.", sectionFolder);
        end

        poseColumn = "Pose" + compose("%02d_s", pose);
        poseTimes = double(timestampTable.(poseColumn));
        expectedTimestampUs = uint64(round(posixtime( ...
            scanStart + seconds(poseTimes))*1e6));
        actualTimestampUs = uint64([sequence.Headers.TimestampUnixUs]).';
        timestampErrors = timestampErrors ...
            + nnz(actualTimestampUs ~= expectedTimestampUs);

        for repeat = sampleRepeats
            sourceImage = h5read(scanPath, "/Data", ...
                [1, plane, 1, 1, pose, repeat], [sizeX, 1, sizeZ, 1, 1, 1]);
            expectedImage = single(reshape(sourceImage, [sizeX, sizeZ]).');
            actualImage = single(sequence.readGray(repeat));
            if ~isequal(size(actualImage), [sizeZ, sizeX])
                error("fUS:ConvertedPDIShapeMismatch", ...
                    "Image shape mismatch in %s frame %d.", sectionFolder, repeat);
            end
            currentError = max(abs(double(actualImage(:)) ...
                - double(expectedImage(:))));
            maximumError = max(maximumError, currentError);
            comparedImages = comparedImages + 1;
        end
    end

    if maximumError ~= 0 || timestampErrors ~= 0
        error("fUS:ConversionValueMismatch", ...
            "Group %d has payload or timestamp mismatches.", groupNumber);
    end
    pdiFileCount = numel(dir(fullfile(groupFolder, "**", "*.pdi")));
    expectedFileCount = poseCount*planeCount*repeatCount;
    if pdiFileCount ~= expectedFileCount
        error("fUS:ConversionFileCountMismatch", ...
            "Group %d expected %d PDI files but found %d.", ...
            groupNumber, expectedFileCount, pdiFileCount);
    end

    report(row, :) = {groupNumber, string(manifest.Condition(row)), ...
        poseCount*planeCount, pdiFileCount, repeatCount, comparedImages, ...
        maximumError, timestampErrors};
    fprintf("PASS group %d: %d sections, %d files, %d images bit-exact\n", ...
        groupNumber, poseCount*planeCount, pdiFileCount, comparedImages);
end

writetable(report, fullfile(outputRoot, "validation_summary.csv"));
fprintf("Validation complete: %d groups, %d PDI files, max error %.9g\n", ...
    height(report), sum(report.PDIFileCount), max(report.MaxAbsoluteError));
end
