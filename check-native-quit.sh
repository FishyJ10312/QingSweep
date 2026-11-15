#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
python3 - <<'PY'
from pathlib import Path
import plistlib
b=Path('.build/QingSweepQuitFixture.app/Contents');(b/'MacOS').mkdir(parents=True,exist_ok=True)
(b/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'QuitFixture','CFBundleIdentifier':'local.qingsweep.fixture.quit','CFBundleName':'轻扫退出测试','CFBundlePackageType':'APPL','CFBundleVersion':'1'}))
PY
xcrun swiftc Tests/Fixtures/QuitApplication.swift -o .build/QingSweepQuitFixture.app/Contents/MacOS/QuitFixture
codesign --force --sign - .build/QingSweepQuitFixture.app
source ./source-list.sh
xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache "${core[@]}" Sources/CleanupExecution.swift Tests/NativeQuitTests.swift -o .build/native-quit-tests
.build/native-quit-tests
