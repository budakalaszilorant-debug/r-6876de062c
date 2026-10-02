#!/bin/sh
# A dugós (közvetlen ELM327) mód értelmezőjének tesztjei. macOS-en (Xcode parancssori eszközökkel) fut.
set -eu
cd "$(dirname "$0")/../.."
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
swiftc SubaruCompanion/Core/ElmParser.swift Tests/Elm/main.swift -o "$OUT/elm-tests"
"$OUT/elm-tests"
