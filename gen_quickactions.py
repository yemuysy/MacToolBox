#!/usr/bin/env python3
"""生成 MacToolBox 的 Finder 快速操作（Quick Action）。

产出一个 .workflow 放到 ~/Library/Services/，右键文件即可在
「快速操作」子菜单看到「MacToolBox」，点击后把选中的文件路径通过
mactoolbox://pick?paths=... 交给主程序弹出动作选择器。

免费、无需证书，ad-hoc 签名也能稳定出现在 Finder 右键。
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

INFO = {
    "AMApplicationBuild": "1",
    "AMApplicationVersion": "1.0",
    "CFBundleName": "MacToolBox",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": "1",
    "NeedsToBeRunAsAppleScript": False,
    "NSAppleScriptEnabled": False,
    "conformsToSystemMetadata": True,
}

WF = {
    "AMDocumentVersion": "2",
    "actions": [
        {
            "action": {
                "AMAccepts": {
                    "Container": "List",
                    "Items": {"0": {"Type": "com.apple.cocoa.path"}},
                },
                "AMActionVersion": "2.0.1",
                "AMApplication": {
                    "AMApplicationBundleIdentifier": "com.apple.Automator",
                    "AMApplicationName": "Automator",
                    "AMApplicationVersion": "1.0",
                    "AMBuildVersion": "1",
                },
                "AMParameterProperties": {},
                "AMProvides": {
                    "Container": "List",
                    "Items": {"0": {"Type": "com.apple.cocoa.string"}},
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
                },
                "BundleIdentifier": "com.apple.RunShellScript",
                "CFBundleVersion": "2.0.1",
                "Command": SCRIPT,
                "Input": "filePaths",
                "MSOActionCompatibleVersion": "1",
            },
            "isViewVisible": True,
        }
    ],
    "connectors": {},
    "workflowMetaData": {
        "clientOSTypes": ["macos"],
        "extensionOverlayIsShown": True,
        "fileExtensionOverlay": "",
        "receivesInput": True,
        "inputType": "fileOrFolder",
        "applicationBundleIdentifier": "com.apple.finder",
        "serviceType": "1",
        "iconImagePath": "",
        "workflowType": "1",
        "color": "Indigo",
    },
}

if os.path.exists(WF_PATH):
    shutil.rmtree(WF_PATH)
os.makedirs(WF_PATH, exist_ok=True)
with open(os.path.join(WF_PATH, "Info.plist"), "wb") as f:
    plistlib.dump(INFO, f)
with open(os.path.join(WF_PATH, "document.wflow"), "wb") as f:
    plistlib.dump(WF, f)

print("created:", WF_PATH)
