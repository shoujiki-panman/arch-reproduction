#!/bin/sh
# 「AIに頼む」の読み取りを、Macの内蔵AI（iPhoneと同じ世代）で測る。
# アプリの Agent.swift から読み取りの部分だけを抜き出して、そのまま使う（写しを作らない）。
# 使い方: tools/ask-eval/run.sh   （macOS 26 以降・Apple Intelligence がオン）
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../../NIPeekaboo/Agent.swift"
WORK=$(mktemp -d)
awk '/^\/\/ MARK: - 何をしたいか/{on=1} /^\/\/ MARK: - 先回り/{on=0} on' "$SRC" > "$WORK/core.swift"
sed -i '' '1i\
import Foundation\
import MapKit\
#if canImport(FoundationModels)\
import FoundationModels\
#endif
' "$WORK/core.swift"
cp "$HERE/main.swift" "$WORK/main.swift"
swiftc -O "$WORK/core.swift" "$WORK/main.swift" -o "$WORK/ask-eval"
"$WORK/ask-eval"
