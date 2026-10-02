#!/bin/zsh
# 編譯 In_Unison42 → build/In_Unison42.app（選單列 app；帶子指令執行＝原本的 CLI）
#
#   ./build.sh                 除錯版（預設）：-Onone -j10、-D DEBUG -D IU42_DIAG（含危險診斷指令），目標 < 5 秒
#   ./build.sh --release       正式版：-O＋WMO（whole-module），不含診斷（-D IU42_DIAG 不加 → 診斷整段不編進去）
#   ./build.sh --install       正式版編譯＋安裝到 ~/Applications/In_Unison42.app（--install 一律用正式版）
#   ./build.sh --install-debug 除錯版編譯＋安裝（要在安裝版上跑診斷時才用；面板／log 會顯示 debug）
#   ./build.sh --no-sign       不簽章（只給編譯檢查；權限會失效，不能 --install）
#
#   * 原始碼：Sources/**/*.swift（全部編進同一個 module）＋ build/gen/BuildStamp.swift（自動產生，見下）
#   * buildStamp：git describe --always --dirty＋建置時間＋debug/release，寫進 build/gen/BuildStamp.swift、加 -D IU42_BUILDSTAMP 一起編
#     （直接 swiftc 編 Sources/ 的建置沒有這個檔 → buildStamp = "dev-unstamped"）
#   * Info.plist → Contents/Info.plist（LSUIElement、NSAudioCaptureUsageDescription、NSMicrophoneUsageDescription…）
#   * 簽章：Hardened Runtime＋In_Unison42.entitlements（麥克風），不開 sandbox。
#     預設 ad-hoc（-）：任何人都能編，但系統音訊錄製（TCC）權限每次重新編譯都要重新授權。
#     有 Apple Development 憑證就設 IN_UNISON42_SIGN_IDENTITY="Apple Development: 你的名字 (TEAMID)"（security find-identity -v -p codesigning 查）：
#     同一個身分簽的新版本，designated requirement 不變 → 權限不會因為重新編譯而失效。debug 與 release 都簽同一個身分。
#   * build/In_Unison42 是指向 app 內執行檔的 symlink，CLI 照舊：./build/In_Unison42 devices
#   * build/In_Unison42.app/Contents/Resources/build-flavor 記錄這次是 debug 還是 release（--install 會檢查）
set -e
zmodload zsh/datetime
cd "${0:A:h}"

FLAVOR=debug
INSTALL=0
SIGN=1
for a in "$@"; do
  case "$a" in
    --release) FLAVOR=release ;;
    --debug) FLAVOR=debug ;;
    --install) INSTALL=1; INSTALL_FLAVOR=release ;;
    --install-debug) INSTALL=1; INSTALL_FLAVOR=debug ;;
    --no-sign) SIGN=0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "✗ 未知參數：$a（./build.sh --help）" >&2; exit 2 ;;
  esac
done
if (( INSTALL )); then
  # --install 只接受正式版：明確寫 --debug --install 視為錯誤，要裝除錯版請用 --install-debug
  if [[ "$INSTALL_FLAVOR" == release && " $* " == *" --debug "* ]]; then
    echo "✗ --install 只安裝正式版；要安裝除錯版請明確用 --install-debug" >&2; exit 2
  fi
  FLAVOR=$INSTALL_FLAVOR
  if (( ! SIGN )); then echo "✗ --install 必須簽章（不能配 --no-sign）" >&2; exit 2; fi
fi

IDENTITY="${IN_UNISON42_SIGN_IDENTITY:--}"   # 預設 ad-hoc；正式簽章請設環境變數
APP=build/In_Unison42.app
BIN="$APP/Contents/MacOS/In_Unison42"

if (( SIGN )) && [[ "$IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\""; then
  echo "✗ 找不到簽章身分：$IDENTITY（security find-identity -v -p codesigning）" >&2
  echo "  要用 ad-hoc 簽章請設 IN_UNISON42_SIGN_IDENTITY=-（系統音訊錄製權限每次重編都要重新授權）" >&2
  exit 1
fi

# buildStamp：git describe（含 -dirty）＋時間＋種類
DESC=$(git describe --always --dirty 2>/dev/null || echo "nogit")
STAMP="${DESC}-$(date +%Y%m%d-%H%M%S)-${FLAVOR}"
mkdir -p build/gen "$APP/Contents/MacOS" "$APP/Contents/Resources"
GEN=build/gen/BuildStamp.swift
print -r -- "// 自動產生（build.sh）：不要手動改、不要提交
let iu42GeneratedBuildStamp = \"$STAMP\"" > "$GEN"

SOURCES=("${(@f)$(find Sources -name '*.swift' | LC_ALL=C sort)}")
COMMON=(-swift-version 5 -module-name In_Unison42 -target arm64-apple-macos14.4 -D IU42_BUILDSTAMP
        -framework CoreAudio -framework AudioToolbox -framework Accelerate
        -framework SwiftUI -framework AppKit -framework ServiceManagement)
if [[ $FLAVOR == release ]]; then
  OPT=(-O -wmo -num-threads 8)
else
  OPT=(-Onone -j10 -D DEBUG -D IU42_DIAG)
fi
T0=$EPOCHREALTIME
swiftc "${OPT[@]}" "${COMMON[@]}" "${SOURCES[@]}" "$GEN" -o "$BIN"
T1=$EPOCHREALTIME
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
print -r -- "$FLAVOR $STAMP" > "$APP/Contents/Resources/build-flavor"

if (( SIGN )); then
  codesign --force --options runtime --timestamp=none \
    --entitlements In_Unison42.entitlements --sign "$IDENTITY" "$APP"
  codesign --verify --strict "$APP"
fi

# 舊版的 build/In_Unison42 是一般執行檔：移到垃圾桶（不 rm），改成 symlink
if [[ -e build/In_Unison42 && ! -L build/In_Unison42 ]]; then
  mv build/In_Unison42 ~/.Trash/"In_Unison42.old-$(date +%Y%m%d-%H%M%S)"
fi
[[ -L build/In_Unison42 ]] || ln -s In_Unison42.app/Contents/MacOS/In_Unison42 build/In_Unison42

printf '✓ %s（%s，%d 個 .swift，編譯 %.1f 秒，buildStamp %s，簽章：%s）\n' \
  "$APP" "$FLAVOR" ${#SOURCES[@]} $(( T1 - T0 )) "$STAMP" "$( (( SIGN )) || { echo 未簽章; exit; }; [[ "$IDENTITY" == - ]] && echo "ad-hoc（-）" || print -r -- "$IDENTITY")"

# 安裝：複製到 ~/Applications/In_Unison42.app（登入項目 SMAppService 只接受「應用程式」資料夾裡的 app）。
#   舊版先移到垃圾桶（不 rm）；執行中的 app 不會被停掉——要自己結束再 open 新版。
if (( INSTALL )); then
  read -r GOT _ < "$APP/Contents/Resources/build-flavor"
  if [[ "$GOT" != "$FLAVOR" ]]; then echo "✗ 剛編好的是 $GOT，不是 $FLAVOR，不安裝" >&2; exit 1; fi
  DEST="$HOME/Applications/In_Unison42.app"
  mkdir -p "$HOME/Applications"
  if [[ -e "$DEST" ]]; then
    mv "$DEST" ~/.Trash/"In_Unison42.app.old-$(date +%Y%m%d-%H%M%S)"
  fi
  ditto "$APP" "$DEST"
  codesign --verify --strict "$DEST"
  echo "✓ 已安裝 $FLAVOR 版到 $DEST"
fi
