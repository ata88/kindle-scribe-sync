#!/usr/bin/env bash
# Which way of getting images into Apple Notes delivers the real image data, at the right position?
# Measure: Notes returns the body with data URIs; "(null)" means the image never loaded.
set -u
OUT="${1:-lab-out}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/notes2.txt"
exec > >(tee -a "$LOG") 2>&1
osa() { perl -e 'alarm 120; exec @ARGV' osascript "$@"; }
sw_vers

grant() { sudo sqlite3 "$1" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified) VALUES ('$2','$3',$4,2,3,1,NULL,NULL,0,'$5',NULL,0,$(date +%s));" 2>&1 | head -2; }
CLIENTS="/usr/bin/osascript /bin/bash /bin/zsh /bin/sh /usr/bin/perl /usr/bin/perl5.34 /usr/sbin/screencapture"
for c in $(ls -d /Users/runner/actions-runner/*/bin/Runner.Worker /Users/runner/actions-runner/*/bin/Runner.Listener /opt/hca/hosted-compute-agent 2>/dev/null); do CLIENTS="$CLIENTS $c"; done
for db in "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "/Library/Application Support/com.apple.TCC/TCC.db"; do
  for c in $CLIENTS; do grant "$db" kTCCServiceAppleEvents "$c" 1 com.apple.Notes; grant "$db" kTCCServiceAppleEvents "$c" 1 com.apple.systemevents
    grant "$db" kTCCServiceScreenCapture "$c" 1 UNUSED; grant "$db" kTCCServiceAccessibility "$c" 1 UNUSED; done
done

# test images in a path like the app's (spaces, inside ~/Library/Application Support)
LIB="$HOME/Library/Application Support/Scribe Sync Lab/pages/nb 1"; mkdir -p "$LIB"
cat > "$OUT/mk.swift" <<'SWIFT'
import AppKit
func make(_ path: String, _ label: String) {
  let w = 500, h = 360
  let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
  c.setStrokeColor(gray: 0, alpha: 1); c.setLineWidth(10); c.stroke(CGRect(x: 40, y: 40, width: 420, height: 280))
  let a = NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: 90)])
  NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false); a.draw(at: NSPoint(x: 120, y: 120))
  let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
make(CommandLine.arguments[1], "ONE"); make(CommandLine.arguments[2], "TWO")
SWIFT
swift "$OUT/mk.swift" "$LIB/fig-0001-1.png" "$LIB/fig-0001-2.png" && ls -l "$LIB"
F1="$LIB/fig-0001-1.png"; F2="$LIB/fig-0001-2.png"
U1=$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())" "$F1")
U2=$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())" "$F2")

open -a Notes; sleep 12
# get past the first-run welcome sheet
for i in 1 2 3; do
  osascript -e 'tell application "Notes" to activate' -e 'delay 1' -e 'tell application "System Events" to keystroke return' >/dev/null 2>&1
  osascript -e 'tell application "System Events" to tell process "Notes" to click button 1 of sheet 1 of window 1' >/dev/null 2>&1
  osascript -e 'tell application "System Events" to tell process "Notes" to click (every button of every window whose name is "Continue")' >/dev/null 2>&1
  sleep 2
done
screencapture -x "$OUT/n2-start.png"
osa -e 'tell application "Notes" to make new folder with properties {name:"Lab2"}' >/dev/null 2>&1

html() { # title -> html with two images at their places, using src1 src2
  printf '<div><h1>%s</h1></div><div>ERSTER TEXT</div><div><img src="%s" /></div><div>ZWEITER TEXT</div><div><img src="%s" /></div><div>DRITTER TEXT</div>' "$1" "$2" "$3"
}
newnote() { osa - "$1" <<'AS'
on run argv
  tell application "Notes" to return id of (make new note at folder "Lab2" of default account with properties {body:item 1 of argv})
end run
AS
}
setbody() { osa - "$1" "$2" <<'AS'
on run argv
  tell application "Notes" to set body of note id (item 1 of argv) to (item 2 of argv)
end run
AS
}
attach() { osa - "$1" "$2" <<'AS'
on run argv
  tell application "Notes"
    set n to note id (item 1 of argv)
    make new attachment at end of attachments of n with data (POSIX file (item 2 of argv))
  end tell
  return "ok"
end run
AS
}
report() { # id label
  sleep 4
  local b; b=$(osa -e "tell application \"Notes\" to return body of note id \"$1\"")
  local nulls real
  nulls=$(grep -o 'base64,(null)' <<<"$b" | wc -l | tr -d ' ')
  real=$(grep -oE 'base64,[A-Za-z0-9+/=]{500,}' <<<"$b" | wc -l | tr -d ' ')
  local att; att=$(osa -e "tell application \"Notes\" to return count of attachments of note id \"$1\"")
  echo "RESULT $2: real-images=$real null-images=$nulls attachments=$att"
  sed -E 's/base64,[A-Za-z0-9+\/=]{20,}/base64,<DATA>/g' <<<"$b" | tr '\n' ' ' | cut -c1-700; echo
}
shot() {
  osa -e "tell application \"Notes\" to activate" -e "tell application \"Notes\" to show note id \"$1\"" >/dev/null 2>&1
  sleep 3; screencapture -x "$OUT/n2-$2.png"
}

echo "== A: file URLs only (what 1.1.0 does)"
A=$(newnote "$(html 'A file urls' "$U1" "$U2")"); report "$A" A; shot "$A" A

echo "== B: attach the files first (grants Notes read access), then set the body with file URLs"
B=$(newnote "<div><h1>B attach then file urls</h1></div>")
attach "$B" "$F1"; attach "$B" "$F2"; report "$B" B-after-attach
setbody "$B" "$(html 'B attach then file urls' "$U1" "$U2")"; report "$B" B; shot "$B" B
echo "-- B again: set body a second time (no new attach)"
setbody "$B" "$(html 'B attach then file urls (2)' "$U1" "$U2")"; report "$B" B-second-set

echo "== B2: new note, files were already attached to another note earlier in this Notes session"
B2=$(newnote "$(html 'B2 no attach, earlier access' "$U1" "$U2")"); report "$B2" B2

echo "== C: images served over http://127.0.0.1"
( cd "$LIB" && python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > "$OUT/http.pid" ); sleep 2
C=$(newnote "$(html 'C localhost http' "http://127.0.0.1:8765/fig-0001-1.png" "http://127.0.0.1:8765/fig-0001-2.png")"); report "$C" C; shot "$C" C
kill "$(cat "$OUT/http.pid")" 2>/dev/null

echo "== D: restart Notes, then file URLs again without attaching (does access survive?)"
osa -e 'tell application "Notes" to quit'; sleep 5; open -a Notes; sleep 8
D=$(newnote "$(html 'D after restart' "$U1" "$U2")"); report "$D" D

echo "== E: after restart: attach to the same note, then set body (the planned app flow)"
E=$(newnote "<div><h1>E</h1></div>")
attach "$E" "$F1"; attach "$E" "$F2"
setbody "$E" "$(html 'E planned flow' "$U1" "$U2")"; report "$E" E; shot "$E" E
echo "-- E update with changed images (rewrite file, attach again, set body)"
swift "$OUT/mk.swift" "$F1" "$F2" >/dev/null 2>&1
attach "$E" "$F1"; attach "$E" "$F2"
setbody "$E" "$(html 'E planned flow, updated' "$U1" "$U2")"; report "$E" E-update

echo "== F: copy into Notes' own container tmp (may need extra permission)"
NT="$HOME/Library/Containers/com.apple.Notes/Data/tmp/ScribeSyncLab"; mkdir -p "$NT" && cp "$F1" "$F2" "$NT/" && echo "copied" || echo "copy failed"
G1=$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())" "$NT/fig-0001-1.png")
G2=$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())" "$NT/fig-0001-2.png")
Fn=$(newnote "$(html 'F notes container' "$G1" "$G2")"); report "$Fn" F
screencapture -x "$OUT/n2-end.png"
echo "== done"
