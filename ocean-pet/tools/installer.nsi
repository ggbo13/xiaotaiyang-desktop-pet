Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WinVer.nsh"
Name "海洋女仆桌宠"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\OceanMaidDesktopPet"
InstallDirRegKey HKCU "Software\OceanMaidDesktopPet" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
CRCCheck on
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "海洋女仆桌宠"
VIAddVersionKey /LANG=2052 "FileDescription" "海洋女仆桌宠独立安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${APP_VERSION}"
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\OceanMaid.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动海洋女仆桌宠"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
Var AppMutex

!macro HoldMutex
    System::Call 'kernel32::CreateMutexW(p 0, i 0, w "Local\OceanMaidDesktopPet") p .r0 ?e'
    Pop $1
    ${If} $0 == 0
    ${OrIf} $1 == 183
        MessageBox MB_OK|MB_ICONEXCLAMATION "请先从托盘退出海洋女仆桌宠，再安装或卸载。小太阳不需要退出。" /SD IDOK
        SetErrorLevel 2
        Abort
    ${EndIf}
    StrCpy $AppMutex $0
!macroend

Function CheckDirectory
    ClearErrors
    ReadRegStr $0 HKCU "Software\OceanMaidDesktopPet" "InstallLocation"
    ; 首次安装没有注册表项属于正常情况，不能把读取失败传递为目录错误。
    ClearErrors
    ${If} $0 != ""
    ${AndIf} $0 != $INSTDIR
        SetErrors
        Return
    ${EndIf}
    ${GetRoot} "$INSTDIR" $1
    ${If} $INSTDIR == "$1\"
    ${OrIf} $INSTDIR == $PROFILE
    ${OrIf} $INSTDIR == $LOCALAPPDATA
    ${OrIf} $INSTDIR == $DESKTOP
    ${OrIf} $INSTDIR == $WINDIR
    ${OrIf} $INSTDIR == $PROGRAMFILES
        SetErrors
        Return
    ${EndIf}
    IfFileExists "$INSTDIR\OceanMaid.install" valid
    IfFileExists "$INSTDIR\*.*" invalid valid
    invalid:
        SetErrors
    valid:
FunctionEnd

Function .onInit
    SetShellVarContext current
    ${IfNot} ${AtLeastWin10}
        MessageBox MB_OK "需要 Windows 10 或 Windows 11。" /SD IDOK
        Abort
    ${EndIf}
    !insertmacro HoldMutex
    Call CheckDirectory
    ${If} ${Errors}
        MessageBox MB_OK "请选择新的专用空文件夹，或海洋女仆桌宠原安装位置。不能安装到小太阳目录。" /SD IDOK
        Abort
    ${EndIf}
FunctionEnd

Function .onVerifyInstDir
    Call CheckDirectory
FunctionEnd

Function .onInstSuccess
    System::Call 'kernel32::CloseHandle(p $AppMutex)'
FunctionEnd

Section "安装海洋女仆桌宠"
    Call CheckDirectory
    ${If} ${Errors}
        MessageBox MB_OK|MB_ICONSTOP "安装目录不符合要求，请重新选择。" /SD IDOK
        Abort
    ${EndIf}
    !include "${INSTALL_FILES}"
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    CreateShortcut "$DESKTOP\海洋女仆桌宠.lnk" "$INSTDIR\OceanMaid.exe"
    CreateDirectory "$SMPROGRAMS\海洋女仆桌宠"
    CreateShortcut "$SMPROGRAMS\海洋女仆桌宠\海洋女仆桌宠.lnk" "$INSTDIR\OceanMaid.exe"
    CreateShortcut "$SMPROGRAMS\海洋女仆桌宠\卸载.lnk" "$INSTDIR\Uninstall.exe"
    WriteRegStr HKCU "Software\OceanMaidDesktopPet" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OceanMaidDesktopPet" "DisplayName" "海洋女仆桌宠"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OceanMaidDesktopPet" "DisplayVersion" "${APP_VERSION}"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OceanMaidDesktopPet" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OceanMaidDesktopPet" "DisplayIcon" "$INSTDIR\OceanMaid.exe"
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OceanMaidDesktopPet" "NoModify" 1
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OceanMaidDesktopPet" "NoRepair" 1
SectionEnd

Function un.onInit
    SetShellVarContext current
    !insertmacro HoldMutex
FunctionEnd

Section "Uninstall"
    ; 仅在用户主动执行卸载时移除本产品白名单文件；个人设置和未知文件保留。
    !include "${UNINSTALL_FILES}"
    Delete "$DESKTOP\海洋女仆桌宠.lnk"
    Delete "$SMPROGRAMS\海洋女仆桌宠\海洋女仆桌宠.lnk"
    Delete "$SMPROGRAMS\海洋女仆桌宠\卸载.lnk"
    RMDir "$SMPROGRAMS\海洋女仆桌宠"
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "OceanMaidDesktopPet"
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\OceanMaidDesktopPet"
    DeleteRegKey HKCU "Software\OceanMaidDesktopPet"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"
SectionEnd
