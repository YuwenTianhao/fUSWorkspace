function summary = convertScan4DToPDI(sourceRoot, outputRoot, options)
%CONVERTSCAN4DTOPDI Convert 4D HDF5 .scan files into fUSWorkspace PDI series.
%
% Each source scan is split into 16 independent 2-D sequences:
% 4 robot poses x 4 imaging planes. The output keeps the original linear
% Power Doppler values as float32 and writes MRSPDI01 version-2 timestamps.

arguments
    sourceRoot (1, 1) string
    outputRoot (1, 1) string
    options.ChunkRepeats (1, 1) double {mustBeInteger, mustBePositive} = 25
    options.PdiReferenceLinear (1, 1) double {mustBePositive} = 50
    options.PdiDbMultiplier (1, 1) double {mustBePositive} = 20
    options.DisplayGainDb (1, 1) double = -6
    options.DisplayDynamicRangeDb (1, 1) double {mustBePositive} = 56.25
end

sourceRoot = string(sourceRoot);
outputRoot = string(outputRoot);
if ~isfolder(sourceRoot)
    error("fUS:ScanSourceNotFound", "Source folder not found: %s", sourceRoot);
end

manifestPath = fullfile(sourceRoot, "experiment_plans", "experiment_manifest.csv");
if ~isfile(manifestPath)
    error("fUS:ExperimentManifestNotFound", ...
        "Experiment manifest not found: %s", manifestPath);
end

if isfolder(outputRoot)
    existing = dir(outputRoot);
    existing = existing(~ismember({existing.name}, {'.', '..'}));
    if ~isempty(existing)
        error("fUS:ConversionOutputNotEmpty", ...
            "Output folder is not empty; refusing to overwrite: %s", outputRoot);
    end
else
    mkdir(outputRoot);
end

manifest = readtable(manifestPath, TextType="string");
requiredColumns = ["Group", "ScanFile", "Condition", "NominalDuration_s", ...
    "PlanFile", "BaselineStart_s", "BaselineEnd_s"];
if ~all(ismember(requiredColumns, string(manifest.Properties.VariableNames)))
    error("fUS:InvalidExperimentManifest", ...
        "Manifest is missing one or more required columns.");
end

rowCount = height(manifest);
summary = table('Size', [rowCount, 11], ...
    'VariableTypes', ["double", repmat("string", 1, 3), repmat("double", 1, 7)], ...
    'VariableNames', ["Group", "Condition", "ScanFile", "OutputFolder", ...
        "PoseCount", "PlaneCount", "SectionCount", "RepeatCount", ...
        "Duration_s", "ActualFPS", "PDIFileCount"]);

for row = 1:rowCount
    groupNumber = double(manifest.Group(row));
    scanFile = string(manifest.ScanFile(row));
    scanPath = fullfile(sourceRoot, scanFile);
    planPath = fullfile(sourceRoot, "experiment_plans", string(manifest.PlanFile(row)));
    if ~isfile(scanPath)
        error("fUS:ScanFileNotFound", "Scan file not found: %s", scanPath);
    end
    if ~isfile(planPath)
        error("fUS:ExperimentPlanNotFound", "Plan file not found: %s", planPath);
    end

    finalGroupFolder = fullfile(outputRoot, sprintf("group_%02d", groupNumber));
    partialGroupFolder = finalGroupFolder + ".partial";
    if isfolder(finalGroupFolder) || isfolder(partialGroupFolder)
        error("fUS:ConversionGroupExists", ...
            "Group output already exists; refusing to overwrite: %s", finalGroupFolder);
    end
    mkdir(partialGroupFolder);

    fprintf("\n[%s] Inspecting %s\n", clockText(), scanFile);
    dataInfo = h5info(scanPath, "/Data");
    dataSize = double(dataInfo.Dataspace.Size);
    if numel(dataSize) ~= 6
        error("fUS:UnexpectedScanRank", ...
            "Expected 6-D /Data but found %s in %s", mat2str(dataSize), scanPath);
    end

    sizeX = readScalar(scanPath, "/acqMetaData/imgDim/sizeX");
    planeCount = readScalar(scanPath, "/acqMetaData/imgDim/sizeY");
    sizeZ = readScalar(scanPath, "/acqMetaData/imgDim/sizeZ");
    poseCount = readScalar(scanPath, "/acqMetaData/imgDim/npose");
    blockRepeat = readScalar(scanPath, "/acqMetaData/imgDim/nblockRepeat");
    repeatCount = readScalar(scanPath, "/acqMetaData/imgDim/nscanRepeat");
    expectedSize = [sizeX, planeCount, sizeZ, blockRepeat, poseCount, repeatCount];
    if ~isequal(dataSize, expectedSize) || blockRepeat ~= 1
        error("fUS:UnexpectedScanDimensions", ...
            "Unexpected /Data dimensions %s; metadata says %s.", ...
            mat2str(dataSize), mat2str(expectedSize));
    end

    timeVector = double(h5read(scanPath, "/acqMetaData/time"));
    timeVector = timeVector(:);
    if numel(timeVector) ~= poseCount*repeatCount
        error("fUS:InvalidScanTimeVector", ...
            "Expected %d timestamps but found %d.", ...
            poseCount*repeatCount, numel(timeVector));
    end
    poseTimes = reshape(timeVector, poseCount, repeatCount).';
    poseIntervals = median(diff(poseTimes, 1, 1), 1);
    if any(abs(poseIntervals - poseIntervals(1)) > 1e-9) || poseIntervals(1) <= 0
        error("fUS:IrregularPoseTiming", ...
            "Pose time series do not have one shared positive interval.");
    end
    sweepPeriod = poseIntervals(1);
    actualFPS = 1/sweepPeriod;
    expectedDuration = double(manifest.NominalDuration_s(row));
    if abs(repeatCount*sweepPeriod - expectedDuration) > 1e-6
        error("fUS:ScanDurationMismatch", ...
            "Scan duration %.9g s does not match manifest %.9g s.", ...
            repeatCount*sweepPeriod, expectedDuration);
    end

    voxelsToProbe = double(h5read(scanPath, "/acqMetaData/voxelsToProbe"));
    probeToLab = double(h5read(scanPath, "/acqMetaData/probeToLab"));
    if ~isequal(size(voxelsToProbe), [4, 4]) ...
            || ~isequal(size(probeToLab), [4, 4, poseCount])
        error("fUS:InvalidScanGeometry", "Unexpected transform dimensions.");
    end

    x0Mm = voxelsToProbe(4, 1)*1000;
    dxMm = abs(voxelsToProbe(1, 1))*1000;
    z0Mm = abs(voxelsToProbe(4, 3))*1000;
    dzMm = abs(voxelsToProbe(3, 3))*1000;
    requestedNearMm = z0Mm;
    requestedFarMm = z0Mm + (sizeZ - 1)*dzMm;

    scanDateText = string(h5read(scanPath, "/scanMetaData/Date"));
    scanStart = datetime(scanDateText, InputFormat="yyyy-M-d H:m:s", ...
        TimeZone="Asia/Shanghai");
    timestampUnixUs = uint64(round(posixtime(scanStart + seconds(poseTimes))*1e6));

    sectionFolders = strings(poseCount, planeCount);
    sectionRows = poseCount*planeCount;
    sectionManifest = table('Size', [sectionRows, 12], ...
        'VariableTypes', ["double", "double", "double", "string", ...
            repmat("double", 1, 8)], ...
        'VariableNames', ["Section", "Pose", "Plane", "Folder", ...
            "PoseX_mm", "PlaneY_mm", "FirstTime_s", "LastTime_s", ...
            "FrameInterval_s", "ActualFPS", "FrameCount", "PDIFileCount"]);
    section = 0;
    for pose = 1:poseCount
        for plane = 1:planeCount
            section = section + 1;
            sectionName = sprintf("section_%02d_pose_%02d_plane_%02d", ...
                section, pose, plane);
            sectionRoot = fullfile(partialGroupFolder, sectionName);
            sectionFolders(pose, plane) = fullfile(sectionRoot, "SVD");
            mkdir(sectionFolders(pose, plane));
            planeYmm = (voxelsToProbe(4, 2) ...
                + (plane - 1)*voxelsToProbe(2, 2))*1000;
            sectionManifest(section, :) = {section, pose, plane, sectionName, ...
                probeToLab(4, 1, pose)*1000, planeYmm, ...
                poseTimes(1, pose), poseTimes(end, pose), sweepPeriod, ...
                actualFPS, repeatCount, repeatCount};
        end
    end

    copyfile(planPath, fullfile(partialGroupFolder, "experiment_plan.csv"));
    timestampNames = "Pose" + compose("%02d_s", 1:poseCount);
    timestampTable = array2table([(1:repeatCount).', poseTimes], ...
        VariableNames=["Sweep", timestampNames]);
    writetable(timestampTable, fullfile(partialGroupFolder, "pose_timestamps.csv"));
    writetable(sectionManifest, fullfile(partialGroupFolder, "section_manifest.csv"));

    settings = table(actualFPS, "linear", ...
        double(manifest.BaselineStart_s(row)), ...
        double(manifest.BaselineEnd_s(row)), sweepPeriod, ...
        VariableNames=["ActualFPS", "ConversionMode", "BaselineStart_s", ...
            "BaselineEnd_s", "FullSweepPeriod_s"]);
    writetable(settings, fullfile(partialGroupFolder, "fUSWorkspace_settings.csv"));

    fprintf("[%s] Group %d: %d poses x %d planes x %d repeats = %d PDI files\n", ...
        clockText(), groupNumber, poseCount, planeCount, ...
        repeatCount, poseCount*planeCount*repeatCount);
    for firstRepeat = 1:options.ChunkRepeats:repeatCount
        chunkRepeatCount = min(options.ChunkRepeats, ...
            repeatCount - firstRepeat + 1);
        dataBlock = h5read(scanPath, "/Data", ...
            [1, 1, 1, 1, 1, firstRepeat], ...
            [sizeX, planeCount, sizeZ, 1, poseCount, chunkRepeatCount]);

        for localRepeat = 1:chunkRepeatCount
            repeat = firstRepeat + localRepeat - 1;
            for pose = 1:poseCount
                for plane = 1:planeCount
                    rawSection = dataBlock(:, plane, :, 1, pose, localRepeat);
                    image = single(reshape(rawSection, [sizeX, sizeZ]).');
                    if any(~isfinite(image), "all") || any(image < 0, "all")
                        error("fUS:InvalidScanPayload", ...
                            "Non-finite or negative values at repeat %d pose %d plane %d.", ...
                            repeat, pose, plane);
                    end
                    outputPath = fullfile(sectionFolders(pose, plane), ...
                        sprintf("PDI_%06d.pdi", repeat));
                    writePDIv2(outputPath, repeat, timestampUnixUs(repeat, pose), ...
                        image, x0Mm, dxMm, z0Mm, dzMm, ...
                        requestedNearMm, requestedFarMm, ...
                        options.PdiReferenceLinear, options.PdiDbMultiplier, ...
                        options.DisplayGainDb, options.DisplayDynamicRangeDb);
                end
            end
        end
        completed = firstRepeat + chunkRepeatCount - 1;
        fprintf("[%s] Group %d: repeats %d/%d complete\n", ...
            clockText(), groupNumber, completed, repeatCount);
    end

    metadata = struct( ...
        SourceScan=scanFile, Condition=string(manifest.Condition(row)), ...
        DataSize=dataSize, PoseCount=poseCount, PlaneCount=planeCount, ...
        SectionCount=poseCount*planeCount, RepeatCount=repeatCount, ...
        SweepPeriod_s=sweepPeriod, ActualFPS=actualFPS, ...
        X0_mm=x0Mm, Dx_mm=dxMm, Z0_mm=z0Mm, Dz_mm=dzMm, ...
        ProbeToLab=probeToLab, VoxelsToProbe=voxelsToProbe, ...
        ScanStart=scanStart, PDIFormat="MRSPDI01 version 2", ...
        PDIStorage="float32 linear Power Doppler");
    save(fullfile(partialGroupFolder, "conversion_metadata.mat"), "metadata");

    [moved, moveMessage] = movefile(partialGroupFolder, finalGroupFolder);
    if ~moved
        error("fUS:ConversionFinalizeFailed", ...
            "Could not finalize group folder: %s", moveMessage);
    end

    summary(row, :) = {groupNumber, string(manifest.Condition(row)), scanFile, ...
        string(finalGroupFolder), poseCount, planeCount, poseCount*planeCount, ...
        repeatCount, expectedDuration, actualFPS, ...
        poseCount*planeCount*repeatCount};
    writetable(summary(1:row, :), fullfile(outputRoot, "conversion_summary.csv"));
    fprintf("[%s] Group %d finalized: %s\n", ...
        clockText(), groupNumber, finalGroupFolder);
end

writeOutputReadme(outputRoot, sourceRoot, summary);
fprintf("\n[%s] Conversion complete: %d groups, %d PDI files\n", ...
    clockText(), height(summary), sum(summary.PDIFileCount));
end


function value = readScalar(scanPath, datasetPath)
value = double(h5read(scanPath, datasetPath));
if ~isscalar(value) || ~isfinite(value) || value <= 0 || value ~= round(value)
    error("fUS:InvalidScanMetadata", ...
        "Expected a positive integer scalar at %s in %s.", datasetPath, scanPath);
end
end


function writePDIv2(path, sequence, timestampUnixUs, image, ...
    x0Mm, dxMm, z0Mm, dzMm, requestedNearMm, requestedFarMm, ...
    pdiReferenceLinear, pdiDbMultiplier, displayGainDb, displayDynamicRangeDb)

[height, width] = size(image);
fileId = fopen(path, "wb", "ieee-le");
if fileId < 0
    error("fUS:PDIWriteOpenFailed", "Could not create PDI file: %s", path);
end
cleanup = onCleanup(@()fclose(fileId));

mustWrite(fileId, uint8(char("MRSPDI01")), "uint8", 8, path);
mustWrite(fileId, uint32(2), "uint32", 1, path);
mustWrite(fileId, uint32(160), "uint32", 1, path);
mustWrite(fileId, uint32(width), "uint32", 1, path);
mustWrite(fileId, uint32(height), "uint32", 1, path);
mustWrite(fileId, uint64(sequence), "uint64", 1, path);
mustWrite(fileId, uint32(sequence), "uint32", 1, path);
mustWrite(fileId, uint32(sequence), "uint32", 1, path);
mustWrite(fileId, uint32(1), "uint32", 1, path);
mustWrite(fileId, uint64(timestampUnixUs), "uint64", 1, path);
mustWrite(fileId, uint32(1), "uint32", 1, path);
mustWrite(fileId, [x0Mm, dxMm, z0Mm, dzMm, ...
    requestedNearMm, requestedFarMm], "double", 6, path);
mustWrite(fileId, [pdiReferenceLinear, pdiDbMultiplier, ...
    displayGainDb, displayDynamicRangeDb], "double", 4, path);
payloadCount = uint64(width)*uint64(height);
mustWrite(fileId, payloadCount, "uint64", 1, path);
mustWrite(fileId, uint64(4)*payloadCount, "uint64", 1, path);
mustWrite(fileId, uint64(0), "uint64", 1, path);
mustWrite(fileId, image, "single", double(payloadCount), path);
clear cleanup

info = dir(path);
expectedBytes = 160 + 4*double(payloadCount);
if isempty(info) || info.bytes ~= expectedBytes
    error("fUS:PDIWriteSizeMismatch", ...
        "PDI file has an unexpected length: %s", path);
end
end


function mustWrite(fileId, value, precision, expectedCount, path)
written = fwrite(fileId, value, precision);
if written ~= expectedCount
    error("fUS:PDIWriteFailed", "Incomplete write to PDI file: %s", path);
end
end


function text = clockText()
text = char(datetime("now", Format="HH:mm:ss"));
end


function writeOutputReadme(outputRoot, sourceRoot, summary)
lines = [
    "# Converted 4D scan data"
    ""
    "Source: `" + sourceRoot + "`"
    ""
    "Each `group_XX` folder contains 16 independent 2-D PDI sequences: " + ...
        "4 robot poses x 4 imaging planes."
    ""
    "To open one section in fUSWorkspace, select its `section_XX_pose_XX_plane_XX` " + ...
        "folder. The app automatically enters the nested `SVD` folder."
    ""
    "Use `experiment_plan.csv` for the group plan and copy values from " + ...
        "`fUSWorkspace_settings.csv` into the app. Use linear input mode."
    ""
    sprintf("Converted groups: %d", height(summary))
    sprintf("Total PDI files: %d", sum(summary.PDIFileCount))
    ""
    "`pose_timestamps.csv` preserves the measured acquisition time of every pose. " + ...
        "PDI headers also store absolute microsecond timestamps using MRSPDI01 version 2."
    ];
writelines(lines, fullfile(outputRoot, "README.md"));
end
