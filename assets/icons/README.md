# 图标资源

1.5.3采用已确认的MATLAB Apps风格图标：蓝色脑形、红橙色反应区、向下箭头和接收端。蓝色圆框以外为PNG透明区域，不含白色外框；框内浅色底为设计的一部分。

- `fUSWorkspace_AppIcon_master.png`：唯一设计母版。
- `fUSWorkspace_AppIcon_16.png`、`fUSWorkspace_AppIcon_24.png`：MATLAB Apps页。
- `fUSWorkspace_AppIcon_128.png`：中尺寸源资源。
- `fUSWorkspace_AppIcon_256.png`：App窗口与工具箱封面。

打包时，`build/build_mltbx.m` 将16和24像素文件同步到 `app/assets/icons` 及 `resources/assets/icons`，供不同注册基目录加载；无需分别编辑副本。安装包只携带实际使用的16、24和256像素资源，不携带母版。

图像处理使用内置ImageGen（background-extraction）；各尺寸由系统图像缩放导出。以下为去白边编辑的提示词，保留脑区反应被接收的设计含义。

## 编辑提示词

Use case: background-extraction
Asset type: exact approved fUS MATLAB App icon, remove exterior white margin
Input image is the EDIT TARGET, an approved icon. Preserve this exact artwork, layout, colors and all details. This is not a redesign.
Primary request: Remove ONLY the white background/margin OUTSIDE the thick blue rounded-square frame. All area exterior to that blue outer frame, including the four exterior corners, must become true alpha transparency. Keep the pale near-white/cyan interior background INSIDE the blue frame fully intact and opaque. Keep the blue frame, blue brain, orange/red hotspot, downward blue arrow and receiver exactly as in the input. Do not add or remove any other design elements.
Export a square transparent PNG with clean perfectly smooth antialiased rounded-square contour. No white matte, white halo, gray halo, black corner fill, speckled alpha, fringing, surrounding border or shadow outside the blue frame. The blue outer edge must meet the transparent exterior directly. Keep proportions and center alignment; modest transparent margin is fine. No text or watermark.
