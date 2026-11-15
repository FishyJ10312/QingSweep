#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
deliverables_dir="${1:-${project_dir:h:h}/outputs}"
app_dir="$deliverables_dir/轻扫.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$project_dir/.build"
cd "$project_dir"
source ./source-list.sh
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -module-cache-path "$project_dir/.build/module-cache" \
  "${engine[@]}" "${ui[@]}" Sources/QingSweepApp.swift \
  -o "$app_dir/Contents/MacOS/QingSweep"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
if [[ -f "$project_dir/Resources/AppIcon.icns" ]]; then
  cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
fi
"$project_dir/sign-app.sh" "$app_dir"
print "Built: $app_dir"
