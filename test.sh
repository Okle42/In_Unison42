#!/bin/zsh
# test.sh — 一次跑全部離線自測＋實機錄音回歸（不出聲、不開麥克風、不開 tap、不動系統音量／預設裝置）
#
#   ./test.sh                     編測試版（-O、增量編譯）→ 平行跑離線自測 → testdata/dump 每份 pp-reanalyze 對 testdata/expected.json
#   ./test.sh --bin <執行檔>       不編譯，直接測指定的執行檔（例如 build/In_Unison42）
#   ./test.sh --update-expected    用這次的結果重寫 testdata/expected.json（量尺「刻意」改了才用；先確認差異合理）
#   ./test.sh --no-release-gate    略過「發行版沒有診斷指令」檢查（省一次 -Onone 編譯）
#   ./test.sh -v                   失敗項目印完整輸出
#
# 退出碼：0 = 全部通過；非 0 = 有回歸（失敗的項目會列出來，完整輸出在 $OUT/logs/）
# 測試版輸出到 ${IU42_TEST_OUT:-build/test}（增量編譯：第一次約 20 秒，之後只重編改過的檔）。
# 為什麼用 -O：bluetooth-selftest 在 -Onone 要 3 分鐘以上，-O 約 5 秒。
#
# 回歸標準答案 testdata/expected.json：每份錄音、每種測試音、每台裝置的
#   到達時間（平均殘差 ms）、採用數（有算進平均的脈衝數）、離散（ms）＋藍牙寬窗粗定位（比排程晚 ms）＋ pp-reanalyze 退出碼。
#   容許誤差 0.05 ms（採用數、退出碼要完全相同）。testdata/ 在 .gitignore（錄音 130 MB），沒有 testdata/dump 就略過這段。
set -u
zmodload zsh/datetime
cd "${0:A:h}"
ROOT=$PWD
T_START=$EPOCHREALTIME

OUT="${IU42_TEST_OUT:-$ROOT/build/test}"
BIN=""
UPDATE=0
GATE=1
VERBOSE=0
while (( $# )); do
  case "$1" in
    --bin) BIN="${2:A}"; shift ;;
    --update-expected) UPDATE=1 ;;
    --no-release-gate) GATE=0 ;;
    -v) VERBOSE=1 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "✗ 未知參數：$1（./test.sh --help）" >&2; exit 2 ;;
  esac
  shift
done
mkdir -p "$OUT/logs"

SOURCES=("${(@f)$(find "$ROOT/Sources" -name '*.swift' | LC_ALL=C sort)}")
FRAMEWORKS=(-framework CoreAudio -framework AudioToolbox -framework Accelerate -framework SwiftUI -framework AppKit -framework ServiceManagement)

# 增量編譯：output-file-map 放在 $1（每個 flavor 一個資料夾）
build_incremental() {
  local dir=$1; shift
  local exe=$1; shift
  mkdir -p "$dir/obj"
  /usr/bin/env python3 - "$dir" "${SOURCES[@]}" <<'EOF'
import json, os, sys
d = sys.argv[1]
m = {"": {"swift-dependencies": os.path.join(d, "master.swiftdeps")}}
for s in sys.argv[2:]:
    b = os.path.relpath(s).replace("/", "_")[:-6]
    m[s] = {"object": os.path.join(d, "obj", b + ".o"), "swift-dependencies": os.path.join(d, "obj", b + ".swiftdeps")}
new = json.dumps(m, sort_keys=True, indent=1)
p = os.path.join(d, "ofm.json")
if not os.path.exists(p) or open(p).read() != new:
    open(p, "w").write(new)
EOF
  swiftc "$@" -incremental -output-file-map "$dir/ofm.json" -swift-version 5 -module-name In_Unison42 \
    -target arm64-apple-macos14.4 "${SOURCES[@]}" -o "$exe" "${FRAMEWORKS[@]}"
}

FAIL=()
note_fail() { FAIL+=("$1"); }

if [[ -z "$BIN" ]]; then
  BIN="$OUT/In_Unison42-test"
  T0=$EPOCHREALTIME
  if ! build_incremental "$OUT/o" "$BIN" -O -j10 -D DEBUG -D IU42_DIAG > "$OUT/logs/build.log" 2>&1; then
    cat "$OUT/logs/build.log"; echo "✗ 測試版編譯失敗"; exit 1
  fi
  printf '編譯測試版（-O 增量）%.1f 秒\n' $(( EPOCHREALTIME - T0 ))
fi
[[ -x "$BIN" ]] || { echo "✗ 找不到執行檔：$BIN"; exit 1; }

# ── 發行版閘門（背景編譯，-Onone 不帶 IU42_DIAG）──
GATE_PID=""
if (( GATE )); then
  ( build_incremental "$OUT/gate-o" "$OUT/In_Unison42-gate" -Onone -j6 > "$OUT/logs/gate-build.log" 2>&1 ) &
  GATE_PID=$!
fi

# ── 離線自測（平行）──
TESTS=(
  "plan-selftest"
  "autocal-selftest"
  "drift-selftest"
  "engine-selftest"
  "reconnect-selftest"
  "mode-selftest"
  "bluetooth-selftest"
  "calibrate --selftest"
  "panel-snapshot --selftest"
  "config-selftest"
  "log-rotate-selftest"
  "policy-selftest"
  "monitor-selftest --quick"
)
PIDS=()
for t in "${TESTS[@]}"; do
  log="$OUT/logs/${t// /_}.log"
  ( s=$EPOCHREALTIME; "$BIN" ${=t} > "$log" 2>&1; rc=$?; printf '\n__RC=%d __SEC=%.2f\n' $rc $(( EPOCHREALTIME - s )) >> "$log" ) &
  PIDS+=($!)
done

# ── 錄音回歸（平行跑 pp-reanalyze）──
DUMPS=()
if [[ -d testdata/dump ]]; then
  DUMPS=(testdata/dump/*(/N))
  mkdir -p "$OUT/logs/reanalyze"
  for d in "${DUMPS[@]}"; do
    n=${d:t}
    ( "$BIN" pp-reanalyze "$d" > "$OUT/logs/reanalyze/$n.log" 2>&1; echo "__RC=$?" >> "$OUT/logs/reanalyze/$n.log" ) &
  done
fi

wait "${PIDS[@]}"
for t in "${TESTS[@]}"; do
  log="$OUT/logs/${t// /_}.log"
  rc=$(sed -n 's/^__RC=\([0-9]*\).*/\1/p' "$log" | tail -1)
  sec=$(sed -n 's/.*__SEC=\([0-9.]*\).*/\1/p' "$log" | tail -1)
  last=$(grep -v '^__RC=' "$log" | grep -v '^$' | tail -1)
  if [[ "$rc" == 0 ]]; then
    printf '  ✓ %-26s %5ss  %s\n' "$t" "$sec" "$last"
  else
    printf '  ✗ %-26s %5ss  rc=%s  %s\n' "$t" "$sec" "$rc" "$last"
    note_fail "$t"
    if (( VERBOSE )); then sed 's/^/      /' "$log"; else grep '✗' "$log" | head -8 | sed 's/^/      /'; fi
  fi
done
wait   # pp-reanalyze（與閘門編譯）

if (( ${#DUMPS} )); then
  EXP=testdata/expected.json
  if (( UPDATE )); then MODE=update; else MODE=check; fi
  if ! /usr/bin/env python3 - "$MODE" "$EXP" "$OUT/logs/reanalyze" "${DUMPS[@]:t}" <<'EOF'
import json, math, os, re, sys
mode, exp_path, logdir, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
TOL = 0.05   # ms

def num(s):
    return float("nan") if s == "nan" else float(s)

def parse(text):
    """pp-reanalyze 的輸出 → {rc, btCoarseMs, devices: {"<測試音>|<裝置>": {meanMs, spreadMs, used}}}"""
    r = {"rc": None, "btCoarseMs": {}, "devices": {}}
    sig = "single"
    for line in text.splitlines():
        m = re.match(r"^__RC=(\d+)", line)
        if m: r["rc"] = int(m.group(1)); continue
        m = re.match(r"^\s*「(.+?)」（外接）.*比排程晚 ([\d.]+) ms", line)
        if m: r["btCoarseMs"][m.group(1)] = float(m.group(2)); continue
        m = re.match(r"^  \[(.+)\]\s*$", line)
        if m: sig = m.group(1); continue
        # 單一測試音：「  名稱  平均 +0.054  離散 0.040  殘差 +0.037 …  SNR …」
        m = re.match(r"^  (\S.*?)  平均 ([+-]?[\d.]+|nan)  離散 ([\d.]+)  殘差 (.*?)  SNR", line)
        if m:
            used = len(m.group(4).split())
            r["devices"][f"single|{m.group(1)}"] = {"meanMs": num(m.group(2)), "spreadMs": float(m.group(3)), "used": used}
            continue
        # A/B：「    名稱（參考）：平均 +0.000 ms、離散 1.970 ms（有效 3/3）…」
        m = re.match(r"^    (.+?)(?:（參考）)?：平均 ([+-]?[\d.]+|nan) ms、離散 ([\d.]+) ms（有效 (\d+)/(\d+)）", line)
        if m:
            r["devices"][f"{sig}|{m.group(1)}"] = {"meanMs": num(m.group(2)), "spreadMs": float(m.group(3)), "used": int(m.group(4))}
    return r

got = {}
for n in names:
    p = os.path.join(logdir, n + ".log")
    got[n] = parse(open(p, encoding="utf-8").read())

def enc(o):
    if isinstance(o, float) and math.isnan(o): return "nan"
    if isinstance(o, dict): return {k: enc(v) for k, v in o.items()}
    return o

if mode == "update":
    out = {"_說明": "test.sh 產生：pp-reanalyze 每份錄音的標準答案（meanMs=到達時間相對參考喇叭、used=採用數、spreadMs=離散；容許 0.05 ms）",
           "toleranceMs": TOL, "dumps": {n: enc(got[n]) for n in sorted(got)}}
    json.dump(out, open(exp_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1, sort_keys=True)
    print(f"  ✓ 已寫入 {exp_path}（{len(got)} 份）")
    sys.exit(0)

if not os.path.exists(exp_path):
    print(f"  ✗ 沒有 {exp_path}：先跑 ./test.sh --update-expected 產生標準答案"); sys.exit(1)
exp = json.load(open(exp_path, encoding="utf-8"))
tol = exp.get("toleranceMs", TOL)
bad = 0

def close(a, b):
    a = num(a) if isinstance(a, str) else a
    b = num(b) if isinstance(b, str) else b
    if math.isnan(a) or math.isnan(b): return math.isnan(a) and math.isnan(b)
    return abs(a - b) <= tol + 1e-9

for n in sorted(set(exp["dumps"]) | set(got)):
    e, g = exp["dumps"].get(n), got.get(n)
    errs = []
    if e is None: errs.append("expected.json 沒有這份（新錄音？確認後 --update-expected）")
    elif g is None: errs.append("testdata/dump 裡沒有這份錄音")
    else:
        if e["rc"] != g["rc"]: errs.append(f"退出碼 {e['rc']} → {g['rc']}")
        for k in sorted(set(e["btCoarseMs"]) | set(g["btCoarseMs"])):
            a, b = e["btCoarseMs"].get(k), g["btCoarseMs"].get(k)
            if a is None or b is None or not close(a, b): errs.append(f"藍牙粗定位 {k}：{a} → {b} ms")
        for k in sorted(set(e["devices"]) | set(g["devices"])):
            a, b = e["devices"].get(k), g["devices"].get(k)
            if a is None or b is None: errs.append(f"{k}：{'多出' if a is None else '不見了'}"); continue
            if a["used"] != b["used"]: errs.append(f"{k} 採用數 {a['used']} → {b['used']}")
            if not close(a["meanMs"], b["meanMs"]): errs.append(f"{k} 到達 {a['meanMs']} → {enc(b['meanMs'])} ms")
            if not close(a["spreadMs"], b["spreadMs"]): errs.append(f"{k} 離散 {a['spreadMs']} → {b['spreadMs']} ms")
    if errs:
        bad += 1
        print(f"  ✗ {n}")
        for x in errs[:12]: print(f"      {x}")
    else:
        nd = len(g["devices"])
        print(f"  ✓ {n:<16} {nd} 項一致（±{tol} ms）")
sys.exit(1 if bad else 0)
EOF
  then
    note_fail "錄音回歸（pp-reanalyze vs testdata/expected.json）"
  fi
else
  echo "  – 沒有 testdata/dump（錄音不在 git 裡），略過錄音回歸"
fi

# ── 發行版閘門：診斷指令不存在、calibrate 白名單生效 ──
if (( GATE )); then
  wait $GATE_PID 2>/dev/null
  G="$OUT/In_Unison42-gate"
  if [[ ! -x "$G" ]] || grep -q "error:" "$OUT/logs/gate-build.log"; then
    echo "  ✗ 發行版閘門：編譯失敗（$OUT/logs/gate-build.log）"; note_fail "發行版閘門編譯"
  else
    gfail=0
    # 只檢查、不執行（2026-09-29 審查）：IU42_POLICY_DRYRUN=1 讓執行檔只跑政策檢查就回傳。
    # 以前是直接執行危險指令看它有沒有被擋；一旦白名單回歸，test.sh 會真的去播測試音／開麥克風／建第二個 tap。
    gate_expect() {   # gate_expect <期望 rc> <說明> <指令…>
      local want=$1 desc=$2; shift 2
      local out rc
      out=$(IU42_POLICY_DRYRUN=1 "$G" "$@" 2>&1); rc=$?
      if [[ $rc == $want && "$out" == *policy-dryrun:* ]]; then echo "  ✓ 發行版：$desc"; else echo "  ✗ 發行版：$desc（rc=$rc）${out:0:200}"; gfail=1; fi
    }
    gate_absent() {   # gate_absent <符號…>：診斷指令的函式沒有編進發行版（看符號表，不執行）
      local sym hits
      for sym in "$@"; do
        hits=$(nm "$G" 2>/dev/null | grep -c "$sym")
        if [[ $hits == 0 ]]; then echo "  ✓ 發行版：沒有 $sym"; else echo "  ✗ 發行版：$sym 還在（$hits 個符號）"; gfail=1; fi
      done
    }
    # 防呆：閘門自己的 dry-run 必須有效（放行的指令也不能真的執行）
    gate_expect 0 "dry-run 生效（calibrate --pulse 放行但不執行）" calibrate --pulse
    gate_expect 2 "bt-tone-test 拒絕" bt-tone-test raw
    gate_expect 2 "mic-probe 拒絕" mic-probe --none
    gate_expect 2 "engine-live-test 拒絕" engine-live-test
    gate_expect 2 "snapshot-live-test 拒絕" snapshot-live-test
    gate_expect 2 "output-guard set 拒絕" output-guard set x
    gate_expect 2 "calibrate --dump 拒絕" calibrate --pulse --dump /tmp/x
    gate_expect 2 "calibrate chirp（沒有 --pulse）拒絕" calibrate
    gate_expect 2 "calibrate --signal xylo 拒絕" calibrate --pulse --signal xylo
    gate_expect 2 "calibrate --mic auto 拒絕" calibrate --pulse --mic auto
    gate_expect 2 "monitor-selftest 拒絕" monitor-selftest --quick
    gate_absent cmdBTToneTest cmdMicProbe runEngineLiveTest runSnapshotLiveTest runMonitorSelfTest cmdMonitorSim
    # policy-selftest 是純函式自測（不出聲），照常執行
    out=$("$G" policy-selftest 2>&1); rc=$?
    if [[ $rc == 0 ]]; then echo "  ✓ 發行版：policy-selftest"; else echo "  ✗ 發行版：policy-selftest（rc=$rc）${out:0:200}"; gfail=1; fi
    (( gfail )) && note_fail "發行版閘門"
  fi
fi

printf '\n總時間 %.1f 秒\n' $(( EPOCHREALTIME - T_START ))
if (( ${#FAIL} )); then
  echo "✗ 回歸：${#FAIL} 項失敗 —— ${(j:、:)FAIL}（完整輸出：$OUT/logs/）"
  exit 1
fi
echo "✓ 全部通過"
exit 0
