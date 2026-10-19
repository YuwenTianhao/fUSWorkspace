function figureHandle = fUSWorkspaceMatlabApp
%FUSWORKSPACEMATLABAPP MATLAB Apps 页入口。
% 不绑定任何个人数据路径，启动后由用户选择 SVD 数据文件夹。

appFolder = fileparts(mfilename("fullpath"));
coreFolder = fullfile(fileparts(appFolder), "core");
if isfolder(coreFolder)
    addpath(coreFolder);
end

persistent activeController
if ~isempty(activeController) && isvalid(activeController)
    figureHandle = activeController.getFigure();
    if ~isempty(figureHandle) && isvalid(figureHandle)
        activeController.bringToFront();
        return
    end
end

activeController = fUSWorkspaceAppV2();

figureHandle = activeController.getFigure();
setappdata(figureHandle, "fUSWorkspaceController", activeController);
activeController.bringToFront();
end
