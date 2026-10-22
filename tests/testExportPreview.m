function tests = testExportPreview
%TESTEXPORTPREVIEW 预览与导出共用渲染结果，取消不生成文件。
tests = functiontests(localfunctions);
end

function setupOnce(~)
root = fileparts(fileparts(mfilename("fullpath")));
addpath(fullfile(root, "core"), fullfile(root, "app"));
end

function testPreviewMatchesExportRendererAndCanChangeFrameLayoutAndSize(testCase)
specification = fixtureSpecification();
preview = fUSWorkspaceExportPreview(specification);
cleanup = onCleanup(@()delete(preview));
fig = preview.getFigure();
fig.Visible = "off";
imageControl = findall(fig, Tag="ExportPreviewImage");
verifyEqual(testCase, string(imageControl.ScaleMethod), "fit");
verifySize(testCase, imageControl.ImageSource, [480, 800, 3]);
frameControl = findall(fig, Tag="ExportPreviewFrame");
frameControl.Value = 3;
frameControl.ValueChangedFcn(frameControl, []);
configuration = specification.ReportConfiguration;
settings = preview.getSettings();
configuration.Layout = settings.Layout;
configuration.FrameSize = settings.FrameSize;
configuration.CurveFraction = settings.CurveFraction;
configuration.ShowROILabels = settings.ShowROILabels;
renderer = fus.ReportRenderer(configuration);
rendererCleanup = onCleanup(@()delete(renderer));
expected = renderer.render(specification.ImageProvider(3), 1.5);
verifyEqual(testCase, imageControl.ImageSource, expected);
clear rendererCleanup

layout = findall(fig, Tag="ExportPreviewLayout");
layout.Value = "right";
layout.ValueChangedFcn(layout, []);
fraction = findall(fig, Tag="ExportPreviewFraction");
fraction.Value = 45;
fraction.ValueChangedFcn(fraction, []);
settings = preview.getSettings();
verifyEqual(testCase, settings.Layout, "right");
verifyEqual(testCase, settings.CurveFraction, 0.45, AbsTol=1e-12);
sizeControl = findall(fig, Tag="ExportPreviewSize");
sizeControl.Value = [800, 1280];
sizeControl.ValueChangedFcn(sizeControl, []);
verifySize(testCase, imageControl.ImageSource, [800, 1280, 3]);
verifyEqual(testCase, preview.getSettings().FrameSize, [800, 1280]);
clear cleanup
end

function testPureImagePreviewAndCancelDoNotWriteFiles(testCase)
specification = fixtureSpecification();
preview = fUSWorkspaceExportPreview(specification);
cleanup = onCleanup(@()delete(preview));
fig = preview.getFigure();
fig.Visible = "off";
style = findall(fig, Tag="ExportPreviewStyle");
style.Value = "image";
style.ValueChangedFcn(style, []);
imageControl = findall(fig, Tag="ExportPreviewImage");
verifyEqual(testCase, imageControl.ImageSource, specification.PureImageProvider(1));
verifyEqual(testCase, string(findall(fig, Tag="ExportPreviewFraction").Enable), "off");
fig.CloseRequestFcn(fig, []);
verifyEqual(testCase, string(fig.Visible), "off");
verifyEqual(testCase, preview.getSettings().Style, "image");
% 预览只接受内存图像，没有输出路径，也没有VideoWriter。
verifyFalse(testCase, isfield(specification, "OutputPath"));
clear cleanup
end

function specification = fixtureSpecification()
curve = struct(Name="ROI 1", Times=[0.5; 1; 1.5], Values=[0; 2; 1], Color=[1, 0.5, 0.2]);
configuration = struct(ImageTitles="Synthetic section", Curves=curve, ...
    Unit="%ΔPD", ShowColorbar=true, Duration=1.5);
settings = struct(Style="presentation", Layout="bottom", CurveFraction=0.26, ...
    FrameSize=[480, 800], ShowROILabels=false);
specification = struct(FrameCount=3, ActualFPS=2, InitialIndex=1, ...
    Modal=false, Settings=settings, ReportConfiguration=configuration, ...
    ImageProvider=@(index){repmat(uint8(30*index), 24, 16, 3)}, ...
    PureImageProvider=@(index)repmat(uint8(30*index), 240, 160, 3));
end
