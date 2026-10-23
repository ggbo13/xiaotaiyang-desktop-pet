# 安装、数据与发布

## 安装与升级

从 [GitHub Releases](https://github.com/ggbo13/xiaotaiyang-desktop-pet/releases/latest) 下载 `XiaoTaiYang-Setup-版本-构建时间.exe`，退出旧桌宠后运行。当前用户安装，无需管理员权限。默认程序目录是 `%LOCALAPPDATA%\Programs\XiaoTaiYangDesktopPet`；从桌面或开始菜单的“小太阳桌宠”启动。

安装版数据独立保存在 `%LOCALAPPDATA%\XiaoTaiYangDesktopPet\data`。首次安装向导可选旧版 `data` 文件夹，仅复制 `config.json` 与 `todos.json`，包含配置、待办、提醒和养成记录。原文件不变；安装版数据目录已存在时不覆盖。升级在原安装目录运行新版安装包，数据继续使用。

卸载前从托盘退出桌宠；从 Windows“已安装的应用”卸载。卸载只移除清单内程序文件和本产品快捷方式、卸载项；个人数据和未知文件保留。不需要的个人数据请自行备份后管理。旧便携版仍使用其程序目录的 `data`，两种模式不自动同步。开机自启在托盘切换；安装版本的两个脚本入口与自启共用同一数据路径。

安装包与启动器暂未签名，仍可能被 SmartScreen 或安全软件提示，NSIS 不保证零误报。请核对官方仓库和 SHA256；不要关闭安全软件、添加全盘排除或安装不明根证书。

启用自启的安装版首次运行时会把旧便携版自启指向当前安装目录；关闭自启的配置不会被强制开启。两个安装入口统一使用英文脚本路径。升级向导只允许原安装位置，若需要移动请先卸载再安装，个人数据仍保留。

## 本机构建

需要 Windows 10/11、系统 Windows PowerShell 5.1、.NET Framework C# 编译器。首次构建需要网络；固定 NSIS 3.11 来自 Tauri 官方构建依赖镜像，ZIP 的 SHA256 为 `C7D27F780DDB6CFFB4730138CD1591E841F4B7EDB155856901CDF5F214394FA1`，脚本会校验 ZIP、缓存逐文件摘要及编译器版本。NSIS 许可随安装载荷提供。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\release-syntax-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\installer-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\installation-policy-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\installed-launcher-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\basic-functions-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\interval-reminder-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\public-package-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\installer-artifact-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build-installer.ps1
```

产物在 `dist`，包含安装 EXE、SHA256 文本、版本/源文件/载荷摘要清单。新文件名含台北构建时间；已存在的产物不覆盖，构建工作目录和旧包保留。主启动 EXE 只启动已安装脚本，不内嵌或解压 ZIP。

## 公开发布

修改完成后先运行相关测试，再递增 `project.psd1` 的三段版本号。只发布白名单快照；`data`、构建目录、凭据、私人绝对路径、专辑参考图与设计草图不入库。公开查看不代表额外授予素材或代码复用权，本项目暂未添加开源许可证。原版像素人物来自用户提供素材，主题和互动由项目生成；音乐封面来自当前播放器，不随源码分发。

需要 Git、已登录的 GitHub CLI 与上述构建环境：

```powershell
# 首次创建新公开库：仅在用户明确授权时使用
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\publish-release.ps1 -CreateRepository
# 后续版本：构建新安装包，提交干净快照并发布
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\publish-release.ps1
```

脚本将公开快照暂存在 `build` 下的独立目录，不提交混合工作目录，不改全局 Git 认证与身份。遇到已有同版本、远端意外文件或非预期仓库就停止，不删除远端文件、不强制推送。提交使用 GitHub noreply 身份。上传后重新下载资产核对 SHA256，并回读公开状态、main 提交和 Release。CI 在 Windows 上运行安全回归并构建安装包，仅上传 Actions 构建产物，不自动创建 Release。

## 测试边界

自动化验证覆盖隔离数据、菜单/计时/养成/动画状态、安装载荷和启动器。真实安装、升级、卸载会写当前用户快捷方式及卸载注册表，执行前应获准测试范围并备份同名快捷方式。播放器实况、系统音频驱动及安全软件信誉判断仍依赖目标电脑环境；不能宣称对所有播放器或所有安全软件完全兼容。
