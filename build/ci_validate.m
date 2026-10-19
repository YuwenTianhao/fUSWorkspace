function ci_validate
%CI_VALIDATE Run the same tests and package build on every supported platform.
projectFolder = fileparts(fileparts(mfilename("fullpath")));
reportFolder = fullfile(projectFolder, "test-results");
if ~isfolder(reportFolder)
    mkdir(reportFolder);
end
diary(fullfile(reportFolder, "console.log"));
logCleanup = onCleanup(@()diary("off"));
reportPath = fullfile(reportFolder, "environment.json");
report = struct( ...
    AppVersion=strtrim(string(fileread(fullfile(projectFolder, "VERSION")))), ...
    Commit=string(getenv("GITHUB_SHA")), ...
    MATLABRelease=string(version("-release")), ...
    MATLABVersion=string(version), ...
    Architecture=string(computer("arch")), ...
    Products=ver, ...
    Passed=false);
writeReport(reportPath, report);
try
    if string(getenv("GITHUB_REF_TYPE")) == "tag"
        assert(string(getenv("GITHUB_REF_NAME")) == "v" + report.AppVersion, ...
            "发布标签必须与VERSION一致，例如v1.5.2。");
    end
    fprintf("fUS Workspace %s | MATLAB %s | %s\n", ...
        report.AppVersion, report.MATLABRelease, report.Architecture);
    run(fullfile(projectFolder, "tests", "run_all_tests.m"));
    run(fullfile(projectFolder, "build", "build_mltbx.m"));
    assert(isfile(fullfile(projectFolder, "release", ...
        "fUSWorkspace_" + report.AppVersion + ".mltbx")), ...
        "测试通过，但安装包未生成。");
    report.Passed = true;
    writeReport(reportPath, report);
catch errorInfo
    report.ErrorIdentifier = string(errorInfo.identifier);
    report.ErrorMessage = string(errorInfo.message);
    writeReport(reportPath, report);
    disp(getReport(errorInfo, "extended", "hyperlinks", "off"));
    rethrow(errorInfo);
end
clear logCleanup
end

function writeReport(path, report)
fileId = fopen(path, "w", "n", "UTF-8");
assert(fileId >= 0, "无法写入测试环境报告：%s", path);
fileCleanup = onCleanup(@()fclose(fileId));
fprintf(fileId, "%s\n", jsonencode(report, PrettyPrint=true));
clear fileCleanup
end
