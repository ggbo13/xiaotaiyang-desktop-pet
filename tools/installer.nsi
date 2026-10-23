Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WinVer.nsh"
!include "x64.nsh"
!include "StrFunc.nsh"
${UnStrStr}

Name "小太阳桌宠"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\XiaoTaiYangDesktopPet"
InstallDirRegKey HKCU "Software\XiaoTaiYangDesktopPet" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
CRCCheck on
ShowInstDetails show
ShowUninstDetails show
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "小太阳桌宠"
VIAddVersionKey /LANG=2052 "FileDescription" "小太阳桌宠安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "小太阳桌宠项目"
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION "StartPet"
!define MUI_FINISHPAGE_RUN_TEXT "运行小太阳桌宠"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
Page custom DataPage DataPageLeave
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Var AppMutex
Var DataRoot
Var ImportFolder
Var ImportCheck
Var ImportInput
Var ImportBrowse
Var ImportEnabled
Var Dialog
Var ImportStage

!macro HoldAppMutex PREFIX
    System::Call 'kernel32::CreateMutexW(p 0, i 0, w "Global\XiaoTaiYangDesktopPet") p .r0 ?e'
    Pop $1
    ${If} $0 == 0
    ${OrIf} $1 != 0
        MessageBox MB_OK|MB_ICONEXCLAMATION "请先从托盘退出正在运行的小太阳桌宠，再安装或卸载。" /SD IDOK
        SetErrorLevel 2
        Abort
    ${EndIf}
    StrCpy $AppMutex $0
!macroend

Function .onInit
    SetShellVarContext current
    ${If} ${RunningX64}
        SetRegView 64
    ${EndIf}
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK "需要 Windows 10 或 Windows 11。" /SD IDOK
        SetErrorLevel 3
        Abort
    ${EndIf}
    !insertmacro HoldAppMutex ""
    StrCpy $DataRoot "$LOCALAPPDATA\XiaoTaiYangDesktopPet\data"
    StrCpy $ImportEnabled 0
    StrCpy $ImportFolder ""
    ReadRegStr $0 HKCU "Software\XiaoTaiYangDesktopPet" "InstallLocation"
    ${If} $0 != ""
    ${AndIf} $0 != $INSTDIR
        MessageBox MB_OK "已安装桌宠，请在原位置升级；需要移动时先卸载，个人数据会保留。" /SD IDOK
        SetErrorLevel 3
        Abort
    ${EndIf}
    Call CheckInstallDirectory
    ${If} ${Errors}
        MessageBox MB_OK "请选择空的专用文件夹，或原安装目录。不要选择旧便携版目录或系统目录。" /SD IDOK
        SetErrorLevel 3
        Abort
    ${EndIf}
FunctionEnd

Function CheckInstallDirectory
    ClearErrors
    ; 目录页可在初始化后修改路径，验证与实际写入前都必须检查注册位置。
    ReadRegStr $0 HKCU "Software\XiaoTaiYangDesktopPet" "InstallLocation"
    ClearErrors
    ${If} $0 != ""
    ${AndIf} $0 != $INSTDIR
        SetErrors
        Return
    ${EndIf}
    ${GetRoot} "$INSTDIR" $0
    ${If} $INSTDIR == "$0\"
    ${OrIf} $INSTDIR == $PROFILE
    ${OrIf} $INSTDIR == $LOCALAPPDATA
    ${OrIf} $INSTDIR == $WINDIR
    ${OrIf} $INSTDIR == $DESKTOP
    ${OrIf} $INSTDIR == $PROGRAMFILES
        SetErrors
        Return
    ${EndIf}
    IfFileExists "$INSTDIR\installed-mode.flag" valid
    IfFileExists "$INSTDIR\*.*" invalid valid
    invalid:
        SetErrors
    valid:
FunctionEnd

Function .onVerifyInstDir
    Call CheckInstallDirectory
FunctionEnd

Function ReleaseAppMutex
    ${If} $AppMutex != 0
        System::Call 'kernel32::CloseHandle(p $AppMutex)'
        StrCpy $AppMutex 0
    ${EndIf}
FunctionEnd

Function .onInstSuccess
    Call ReleaseAppMutex
FunctionEnd

Function .onGUIEnd
    Call ReleaseAppMutex
FunctionEnd

Function StartPet
    Call ReleaseAppMutex
    Exec '"$INSTDIR\小太阳桌宠.exe"'
FunctionEnd

Function DataPage
    nsDialogs::Create 1018
    Pop $Dialog
    ${NSD_CreateLabel} 0 0 100% 35u "安装版数据独立保存在：$\r$\n$DataRoot$\r$\n升级和卸载都会保留这些数据。"
    Pop $0
    IfFileExists "$DataRoot\." existing
    ${NSD_CreateCheckbox} 0 44u 100% 14u "可选：从旧版 data 文件夹导入"
    Pop $ImportCheck
    ${NSD_CreateDirRequest} 0 65u 78% 14u "$ImportFolder"
    Pop $ImportInput
    ${NSD_CreateBrowseButton} 80% 65u 20% 14u "浏览…"
    Pop $ImportBrowse
    ${NSD_OnClick} $ImportBrowse BrowseData
    ${NSD_CreateLabel} 0 90u 100% 30u "只复制 config.json 和 todos.json，旧文件保持原样。首次安装可以不导入；已有安装版数据时不会覆盖。"
    Pop $0
    Goto show
    existing:
        ${NSD_CreateLabel} 0 48u 100% 35u "已检测到安装版数据目录，本次更新直接保留，不会导入或覆盖。"
        Pop $0
    show:
    nsDialogs::Show
FunctionEnd

Function BrowseData
    nsDialogs::SelectFolderDialog "选择旧版 data 文件夹" "$ImportFolder"
    Pop $0
    ${If} $0 != error
        ${NSD_SetText} $ImportInput "$0"
    ${EndIf}
FunctionEnd

Function DataPageLeave
    IfFileExists "$DataRoot\." done
    ${NSD_GetState} $ImportCheck $ImportEnabled
    ${If} $ImportEnabled != ${BST_CHECKED}
        Return
    ${EndIf}
    ${NSD_GetText} $ImportInput $ImportFolder
    IfFileExists "$ImportFolder\config.json" done
    IfFileExists "$ImportFolder\todos.json" done
    MessageBox MB_OK|MB_ICONEXCLAMATION "所选文件夹没有旧版 config.json 或 todos.json。"
    Abort
    done:
FunctionEnd

Section "安装小太阳桌宠"
    Call CheckInstallDirectory
    ${If} ${Errors}
        MessageBox MB_OK|MB_ICONSTOP "安装目录不再有效，请退出后在原安装位置升级。" /SD IDOK
        SetErrorLevel 3
        Abort
    ${EndIf}
    !include "${INSTALL_FILES}"
    ${If} $ImportEnabled == ${BST_CHECKED}
        ; 先复制到全新暂存目录，最后整体重命名，避免半份导入或覆盖已有数据。
        IfFileExists "$DataRoot\." import_done
        System::Call 'kernel32::GetTickCount() i .r0'
        System::Call 'kernel32::GetCurrentProcessId() i .r1'
        StrCpy $ImportStage "$DataRoot.import-$0-$1"
        IfFileExists "$ImportStage\." import_failed
        CreateDirectory "$ImportStage"
        ClearErrors
        IfFileExists "$ImportFolder\config.json" 0 +3
            CopyFiles /SILENT "$ImportFolder\config.json" "$ImportStage"
            IfErrors import_failed
        IfFileExists "$ImportFolder\todos.json" 0 +3
            CopyFiles /SILENT "$ImportFolder\todos.json" "$ImportStage"
            IfErrors import_failed
        Rename "$ImportStage" "$DataRoot"
        IfErrors import_failed
        Goto import_done
        import_failed:
            MessageBox MB_OK|MB_ICONSTOP "旧数据导入失败，安装未完成。原文件未改变，暂存文件也已保留，请不要删除旧 data。" /SD IDOK
            SetErrorLevel 4
            Abort
        import_done:
    ${EndIf}
    WriteUninstaller "$INSTDIR\卸载小太阳桌宠.exe"
    CreateDirectory "$SMPROGRAMS\小太阳桌宠"
    CreateShortcut "$SMPROGRAMS\小太阳桌宠\小太阳桌宠.lnk" "$INSTDIR\小太阳桌宠.exe"
    CreateShortcut "$SMPROGRAMS\小太阳桌宠\卸载.lnk" "$INSTDIR\卸载小太阳桌宠.exe"
    CreateShortcut "$DESKTOP\小太阳桌宠.lnk" "$INSTDIR\小太阳桌宠.exe"
    WriteRegStr HKCU "Software\XiaoTaiYangDesktopPet" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "DisplayName" "小太阳桌宠"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "DisplayVersion" "${APP_VERSION}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "Publisher" "小太阳桌宠项目"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "DisplayIcon" "$INSTDIR\小太阳桌宠.exe"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "UninstallString" '$\"$INSTDIR\卸载小太阳桌宠.exe$\"'
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "QuietUninstallString" '$\"$INSTDIR\卸载小太阳桌宠.exe$\" /S'
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "URLInfoAbout" "https://github.com/ggbo13/xiaotaiyang-desktop-pet"
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "NoModify" 1
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet" "NoRepair" 1
SectionEnd

Function un.CheckRegisteredLocation
    ReadRegStr $0 HKCU "Software\XiaoTaiYangDesktopPet" "InstallLocation"
    ${If} $0 != ""
    ${AndIf} $0 != $INSTDIR
        MessageBox MB_OK|MB_ICONSTOP "此卸载器不在注册的安装位置，拒绝卸载。请使用原安装目录中的卸载器。" /SD IDOK
        SetErrorLevel 3
        Abort
    ${EndIf}
FunctionEnd

Function un.onInit
    SetShellVarContext current
    ${If} ${RunningX64}
        SetRegView 64
    ${EndIf}
    IfFileExists "$INSTDIR\installed-mode.flag" valid_uninstall
    MessageBox MB_OK|MB_ICONSTOP "未找到安装标记，拒绝从此目录卸载。请使用原安装目录中的卸载器。" /SD IDOK
    SetErrorLevel 3
    Abort
    valid_uninstall:
    Call un.CheckRegisteredLocation
    !insertmacro HoldAppMutex "un."
FunctionEnd

Section "Uninstall"
    ; 只移除本安装器清单内的程序文件，绝不递归删除目录或个人数据。
    !include "${UNINSTALL_FILES}"
    Delete "$INSTDIR\卸载小太阳桌宠.exe"
    RMDir "$INSTDIR"
    Delete "$DESKTOP\小太阳桌宠.lnk"
    Delete "$SMPROGRAMS\小太阳桌宠\小太阳桌宠.lnk"
    Delete "$SMPROGRAMS\小太阳桌宠\卸载.lnk"
    RMDir "$SMPROGRAMS\小太阳桌宠"
    ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "小太阳桌宠"
    ${UnStrStr} $1 $0 '$\"$INSTDIR\xiaotaiyang.ps1$\"'
    ${If} $1 == ""
        ${UnStrStr} $1 $0 '$\"$INSTDIR\小太阳.ps1$\"'
    ${EndIf}
    ${If} $1 != ""
        DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "小太阳桌宠"
    ${EndIf}
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaoTaiYangDesktopPet"
    DeleteRegKey HKCU "Software\XiaoTaiYangDesktopPet"
SectionEnd
