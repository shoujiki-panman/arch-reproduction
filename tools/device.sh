#!/bin/bash
# 実機まわりの3手をまとめたもの。実測日にケーブル1本で使う。
#   ./tools/device.sh list             接続中の端末とUDIDを出す
#   ./tools/device.sh install <UDID>   署名ビルドしてその端末に入れる
#   ./tools/device.sh caps <UDID>      NISession.deviceCapabilities を吐かせる(方向が出る端末か)
#
# DerivedData を既定の場所に置くのは意図的。このリポジトリは同期フォルダ配下にあり、
# 中に置くと成果物に com.apple.FinderInfo が付いて CodeSign が落ちる(ROADMAP参照)。
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
TEAM=59FNRWS2H8
BUNDLE=jp.shutanuma.kokodayo

case "${1:-}" in
list)
  xcrun devicectl list devices
  ;;
install)
  UDID="${2:?UDID を渡してください。./tools/device.sh list で確認できます}"
  xcodebuild -project NIPeekaboo.xcodeproj -scheme NIPeekaboo \
    -destination "platform=iOS,id=$UDID" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build
  APP=$(xcodebuild -project NIPeekaboo.xcodeproj -scheme NIPeekaboo \
        -destination "platform=iOS,id=$UDID" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/NIPeekaboo.app
  xcrun devicectl device install app --device "$UDID" "$APP"
  ;;
caps)
  UDID="${2:?UDID を渡してください}"
  xcrun devicectl device process launch --console --terminate-existing \
    --device "$UDID" "$BUNDLE" -- -previewCaps
  ;;
*)
  sed -n '2,8p' "$0"
  exit 1
  ;;
esac
