% Convert all eight YWTH 4-D HDF5 scan experiments into PDI sequences.
sourceRoot = "D:\Tianhao\YWTH_fus4D_20260917";
outputRoot = fullfile(sourceRoot, "converted_pdi");
projectRoot = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(projectRoot, "scripts"));

summary = convertScan4DToPDI(sourceRoot, outputRoot, ChunkRepeats=25);
disp(summary);
