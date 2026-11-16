#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
mkdir -p .build
source ./source-list.sh
common=("${core[@]}")
compiler=(xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache)
"${compiler[@]}" "${common[@]}" Tests/CoreTests.swift -o .build/core-tests
.build/core-tests
"${compiler[@]}" "${common[@]}" Sources/InteractionSupport.swift Tests/InteractionSupportTests.swift -o .build/interaction-tests
.build/interaction-tests
"${compiler[@]}" "${common[@]}" Sources/StorageAudit.swift Sources/StorageVolumes.swift Tests/StorageAuditTests.swift -o .build/storage-audit-tests
.build/storage-audit-tests
"${compiler[@]}" "${engine[@]}" Tests/AppModelTests.swift -o .build/model-tests
.build/model-tests

"${compiler[@]}" "${engine[@]}" Tests/StorageIndexTests.swift -o .build/index-tests
.build/index-tests

"${compiler[@]}" "${engine[@]}" Tests/CleanupFlowTests.swift -o .build/cleanup-flow-tests
.build/cleanup-flow-tests

"${compiler[@]}" "${engine[@]}" Tests/ManualCleanupTests.swift -o .build/manual-cleanup-tests
.build/manual-cleanup-tests

"${compiler[@]}" "${common[@]}" Sources/CleanupExecution.swift Tests/CleanupExecutionTests.swift -o .build/execution-tests
.build/execution-tests
./check-native-quit.sh

"${compiler[@]}" "${engine[@]}" Tests/StorageCoverageTests.swift -o .build/coverage-tests
.build/coverage-tests

"${compiler[@]}" "${engine[@]}" Tests/StorageResumeTests.swift -o .build/resume-tests
.build/resume-tests

"${compiler[@]}" "${common[@]}" Tests/CompleteListTests.swift -o .build/complete-list-tests
.build/complete-list-tests
"${compiler[@]}" "${engine[@]}" Tests/Release16Tests.swift -o .build/release16-tests
.build/release16-tests

"${compiler[@]}" "${engine[@]}" Sources/Design.swift Sources/SpaceMap.swift Tests/Release17Tests.swift -o .build/release17-tests
.build/release17-tests

"${compiler[@]}" "${engine[@]}" Tests/Release18Tests.swift -o .build/release18-tests
.build/release18-tests

"${compiler[@]}" "${common[@]}" Tests/RetainedRetryTests.swift -o .build/retained-retry-tests
.build/retained-retry-tests

"${compiler[@]}" "${common[@]}" Sources/StartupItems.swift Tests/StartupStateTests.swift -o .build/startup-state-tests
.build/startup-state-tests

"${compiler[@]}" "${engine[@]}" Tests/StorageScopeTests.swift -o .build/storage-scope-tests
.build/storage-scope-tests

"${compiler[@]}" "${engine[@]}" Tests/CrashRecoveryTests.swift -o .build/crash-recovery-tests
.build/crash-recovery-tests

"${compiler[@]}" "${engine[@]}" Tests/LocalizationTests.swift -o .build/localization-tests
.build/localization-tests
