%% 启动 fUS Workspace 开发源码版
projectFolder = fileparts(mfilename("fullpath"));
appFolder = fullfile(projectFolder, "app");
coreFolder = fullfile(projectFolder, "core");
addpath(appFolder, coreFolder);

controller = fUSWorkspaceAppV2();
assignin("base", "fUSWorkspaceController", controller);
