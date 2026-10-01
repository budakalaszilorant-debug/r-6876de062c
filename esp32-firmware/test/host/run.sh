#!/bin/sh
# PC-n futó értelmező tesztek. Kell hozzá g++ (pl. PlatformIO: pio pkg install -g --tool platformio/toolchain-gccmingw32).
cd "$(dirname "$0")" || exit 1
command -v g++ >/dev/null 2>&1 || PATH="$HOME/.platformio/packages/toolchain-gccmingw32/bin:$PATH"
g++ -std=c++11 -Wall -static -I. test_parse.cpp -o test_parse.exe && ./test_parse.exe
