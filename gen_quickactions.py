#!/usr/bin/env python3
"""生成 MacToolBox 的 Finder 快速操作（Quick Action）。

产出一个 .workflow 放到 ~/Library/Services/，右键文件即可在
「快速操作」/「服务」子菜单看到「MacToolBox」，点击后把选中的文件路径通过
mactoolbox://pick?paths=... 交给主程序弹出动作选择器。

免费、无需证书，ad-hoc 签名也能稳定出现在 Finder 右键。

结构严格对齐系统自带 workflow（如 /System/Library/Services/Show Map.workflow）：
  MacToolBox.workflow/Contents/Info.plist              <- 含 NSServices 声明
  MacToolBox.workflow/Contents/Resources/document.wflow <- Automator 工作流
"""
import os
import plistlib
import shutil

SERVICES_DIR = os.path.expanduser("~/Library/Services")
WF_NAME = "MacToolBox.workflow"
WF_PATH = os.path.join(SERVICES_DIR, WF_NAME)

# 收到文件后：逐个 URL-encode，用 | 连接，交给主程序的 URL 协议
SCRIPT = """#!/bin/bash
ENC=""
for f in "$@"; do
  e=$(/usr/bin/python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$f")
  ENC="${ENC}${e}|"
done
ENC="${ENC%|}"
/usr/bin/open "mactoolbox://pick?paths=${ENC}"
"""

# Info.plist：声明为右键服务（NSServices），系统据此注册到 Finder 右键菜单
INFO = {
    "NSServices": [
        {
            "NSMenuItem": {"default": "MacToolBox"},
            "NSMessage": "runWorkflowAsService",
            "NSRequiredContext": {},
            "NSSendTypes": ["NSFilenamesPboardType"],
        }
    ],
    "CFBundleDevelopmentRegion": "en_US",
    "CFBundleIdentifier": "com.yemu.mactoolbox.quickaction",
    "CFBundleName": "MacToolBox",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
}

# document.wflow：Automator 工作流，单个 Run Shell Script 动作
WF = {
    "AMApplicationBuild": "346",
    "AMApplicationVersion": "2.3",
    "AMDocumentVersion": "2",
    "actions": [
        {
            "action": {
                "AMAccepts": {
                    "Container": "List",
                    "Optional": True,
                    "Types": ["com.apple.cocoa.path"],
                },
                "AMActionVersion": "2.0.3",
                "AMApplication": ["Automator"],
                "AMParameterProperties": {
                    "COMMAND_STRING": {},
                    "CheckedForUserDefaultShell": {},
                    "inputMethod": {},
                    "Shell": {},
                    "source": {},
                },
                "AMProvides": {
                    "Container": "List",
                    "Optional": True,
                    "Types": ["com.apple.cocoa.string"],
                },
                "ActionClass": "RunShellScript",
                "ActionName": "Run Shell Script",
                "ActionParameters": {
                    "COMMAND_STRING": SCRIPT,
                    "CheckedForOutput": True,
                    "InputPath": "filePaths",
                    "OutputType": "0",
                    "Shell": "/bin/bash",
                    "source": SCRIPT,
                    "arguments": [{"0": {"default": "", "type": "0"}}],
                    "inputMethod": "0",
                },
                "BundleIdentifier": "com.apple.RunShellScript",
                "CFBundleVersion": "2.0.3",
                "Command": SCRIPT,
                "Input": "filePaths",
            },
            "isViewVisible": True,
        }
    ],
    "connectors": {},
    "workflowMetaData": {
        "clientOSTypes": ["macos"],
        "receivesInput": True,
        "inputType": "fileOrFolder",
        "applicationBundleIdentifier": "com.apple.finder",
        "serviceType": "1",
        "workflowType": "1",
    },
}

if os.path.exists(WF_PATH):
    shutil.rmtree(WF_PATH)
os.makedirs(os.path.join(WF_PATH, "Contents", "Resources"), exist_ok=True)
with open(os.path.join(WF_PATH, "Contents", "Info.plist"), "wb") as f:
    plistlib.dump(INFO, f)
with open(os.path.join(WF_PATH, "Contents", "Resources", "document.wflow"), "wb") as f:
    plistlib.dump(WF, f)

print("created:", WF_PATH)
