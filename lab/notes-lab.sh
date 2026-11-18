#!/usr/bin/env bash
# Experiment: which way of putting images into Apple Notes via AppleScript shows real images?
set -u
OUT="${1:-lab-out}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/lab.txt"
exec > >(tee -a "$LOG") 2>&1
osa() { perl -e 'alarm 90; exec @ARGV' osascript "$@"; }

# test images: a sketch drawn with Swift/CoreGraphics (RGB PNG, gray PNG, JPEG)
cat > "$OUT/mk.swift" <<'SWIFT'
import AppKit
let w = 600, h = 400
func make(_ space: CGColorSpace, _ info: UInt32) -> CGImage {
  let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
  c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
  c.setStrokeColor(gray: 0, alpha: 1); c.setLineWidth(10)
  c.stroke(CGRect(x: 150, y: 60, width: 300, height: 220))
  c.move(to: CGPoint(x: 120, y: 280)); c.addLine(to: CGPoint(x: 300, y: 380)); c.addLine(to: CGPoint(x: 480, y: 280)); c.strokePath()
  return c.makeImage()!
}
func save(_ img: CGImage, _ path: String, _ type: NSBitmapImageRep.FileType) {
  let rep = NSBitmapImageRep(cgImage: img)
  try! rep.representation(using: type, properties: [.compressionFactor: 0.85])!.write(to: URL(fileURLWithPath: path))
}
let dir = CommandLine.arguments[1]
save(make(CGColorSpaceCreateDeviceRGB(), CGImageAlphaInfo.noneSkipLast.rawValue), dir + "/rgb.png", .png)
save(make(CGColorSpaceCreateDeviceGray(), CGImageAlphaInfo.none.rawValue), dir + "/gray.png", .png)
save(make(CGColorSpaceCreateDeviceRGB(), CGImageAlphaInfo.noneSkipLast.rawValue), dir + "/rgb.jpg", .jpeg)
SWIFT
swift "$OUT/mk.swift" "$OUT" && ls -l "$OUT"

echo "== process chain"
p=$$; for i in 1 2 3 4 5 6 7 8; do ps -o pid=,ppid=,comm= -p $p; p=$(ps -o ppid= -p $p | tr -d ' '); [ -z "$p" ] || [ "$p" = "1" ] && break; done
echo "== csrutil"; csrutil status 2>&1
grant() { # db, service, client, client_type, indirect
  sudo sqlite3 "$1" "INSERT OR REPLACE INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified) VALUES ('$2','$3',$4,2,3,1,NULL,NULL,0,'$5',NULL,0,$(date +%s));" 2>&1 | head -2
}
UDB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SDB="/Library/Application Support/com.apple.TCC/TCC.db"
CLIENTS="/usr/bin/osascript /bin/bash /bin/zsh /bin/sh /usr/bin/perl /usr/bin/perl5.34"
for c in $(ls -d /Users/runner/actions-runner/*/bin/Runner.Worker /Users/runner/actions-runner/*/bin/Runner.Listener /opt/hca/hosted-compute-agent 2>/dev/null); do CLIENTS="$CLIENTS $c"; done
for db in "$UDB" "$SDB"; do
  for c in $CLIENTS; do grant "$db" kTCCServiceAppleEvents "$c" 1 com.apple.Notes; grant "$db" kTCCServiceAppleEvents "$c" 1 com.apple.systemevents; grant "$db" kTCCServiceScreenCapture "$c" 1 UNUSED; done
done
echo "granted to: $CLIENTS"
open -a Notes; sleep 10
screencapture -x "$OUT/notes-start.png" 2>&1
echo "== Notes windows/buttons"
osascript -e 'tell application "System Events" to tell process "Notes" to get {name of every window, name of every button of every window}' 2>&1 | head -3
# dismiss a first-run welcome sheet if present (Continue / Weiter / Fortfahren)
for b in Continue Weiter Fortfahren "Get Started" OK; do
  osascript -e "tell application \"System Events\" to tell process \"Notes\" to click (first button of every window whose name is \"$b\")" >/dev/null 2>&1
  osascript -e "tell application \"System Events\" to tell process \"Notes\" to click button \"$b\" of window 1" >/dev/null 2>&1
done
sleep 3
screencapture -x "$OUT/notes-after-welcome.png" 2>&1
osascript -e 'tell application "System Events" to tell process "Notes" to get {name of every window, name of every button of every window}' 2>&1 | head -3
echo "== accounts"; osa -e 'tell application "Notes" to get name of every account'
osa -e 'tell application "Notes" to make new folder with properties {name:"Lab"}' >/dev/null 2>&1

b64() { base64 -i "$1" | tr -d '\n'; }
mk() { # name, html file
  osa - "$1" "$2" <<'AS'
on run argv
  set htmlBody to read (POSIX file (item 2 of argv)) as «class utf8»
  tell application "Notes"
    set f to folder "Lab" of default account
    set n to make new note at f with properties {body:htmlBody}
    return id of n
  end tell
end run
AS
}
report() { # note id
  osa - "$1" <<'AS'
on run argv
  tell application "Notes"
    set n to note id (item 1 of argv)
    set out to "name=" & (name of n) & " attachments=" & (count of attachments of n)
    repeat with a in attachments of n
      try
        set out to out & linefeed & "   att name=" & (name of a) & " cid=" & (content identifier of a)
      on error e
        set out to out & linefeed & "   att (props error " & e & ")"
      end try
    end repeat
    set b to body of n
    set out to out & linefeed & "   body length=" & (length of b)
    if b contains "<img" then set out to out & " has-img-tag"
    if b contains "data:image" then set out to out & " has-data-uri"
    return out
  end tell
end run
AS
}
shot() { # note id, png name
  osa -e "tell application \"Notes\" to activate" -e "tell application \"Notes\" to show note id \"$1\"" >/dev/null 2>&1
  sleep 3
  screencapture -x "$OUT/$2.png" 2>&1 || echo "screencapture failed"
}

PNG=$(b64 "$OUT/rgb.png"); GRAY=$(b64 "$OUT/gray.png"); JPG=$(b64 "$OUT/rgb.jpg")
declare -a NAMES
printf '<div><h1>V1 png data self-closed</h1></div><div>Text davor</div><div><img src="data:image/png;base64,%s" /></div><div>Text danach</div>' "$PNG" > "$OUT/v1.html"
printf '<div><h1>V2 jpeg data</h1></div><div>Text davor</div><div><img src="data:image/jpeg;base64,%s"></div><div>Text danach</div>' "$JPG" > "$OUT/v2.html"
printf '<div><h1>V3 gray png data (old app)</h1></div><div>Text davor</div><div><img src="data:image/png;base64,%s"></div><div>Text danach</div>' "$GRAY" > "$OUT/v3.html"
printf '<div><h1>V4 file url</h1></div><div>Text davor</div><div><img src="file://%s" /></div><div>Text danach</div>' "$OUT/rgb.png" > "$OUT/v4.html"
printf '<html><body><h1>V5 p-wrapped png with size</h1><p>Text davor</p><p><img src="data:image/png;base64,%s" width="300" height="200" alt="Skizze"/></p><p>Text danach</p></body></html>' "$PNG" > "$OUT/v5.html"
printf '<div><h1>V6 two images</h1></div><div>A</div><div><img src="data:image/png;base64,%s" /></div><div>B</div><div><img src="data:image/jpeg;base64,%s" /></div><div>C</div>' "$PNG" "$JPG" > "$OUT/v6.html"

for v in 1 2 3 4 5 6; do
  id=$(mk "V$v" "$OUT/v$v.html"); echo "== V$v id=$id"
  if [ -n "$id" ]; then sleep 4; report "$id"; shot "$id" "V$v"; eval "ID$v=$id"; fi
done

echo "== V7 attachment command"
id7=$(osa - "$OUT/rgb.png" <<'AS'
on run argv
  tell application "Notes"
    set f to folder "Lab" of default account
    set n to make new note at f with properties {body:"<div><h1>V7 attachment</h1></div><div>Text davor</div><div>Text danach</div>"}
    try
      make new attachment at end of attachments of n with data (POSIX file (item 1 of argv))
    on error e
      try
        tell n to make new attachment with data (POSIX file (item 1 of argv))
      on error e2
        return "ERR " & e & " / " & e2
      end try
    end try
    return id of n
  end tell
end run
AS
)
echo "id=$id7"; case "$id7" in x-coredata*) sleep 4; report "$id7"; shot "$id7" V7;; esac

echo "== V9 file URLs with spaces, two images, order + repeated updates"
SP="$OUT/Application Support/Scribe Sync/pages"; mkdir -p "$SP"
cp "$OUT/rgb.png" "$SP/fig 1.png"; cp "$OUT/gray.png" "$SP/fig-2.png"
U1=$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())" "$SP/fig 1.png")
U2=$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).as_uri())" "$SP/fig-2.png")
echo "U1=$U1"
printf '<div><h1>V9 file urls</h1></div><div>ERSTER TEXT</div><div><img src="%s" /></div><div>ZWEITER TEXT</div><div><img src="%s" /></div><div>DRITTER TEXT</div>' "$U1" "$U2" > "$OUT/v9.html"
id9=$(mk V9 "$OUT/v9.html"); echo "id=$id9"; sleep 4; report "$id9"
dump() {
  osa - "$1" <<'AS' | sed -E 's/base64,[A-Za-z0-9+\/=]{20,}/base64,…/g'
on run argv
  tell application "Notes" to return body of note id (item 1 of argv)
end run
AS
}
echo "-- body V9:"; dump "$id9"
for k in 1 2 3; do
  osa - "$id9" "$OUT/v9.html" <<'AS'
on run argv
  set htmlBody to read (POSIX file (item 2 of argv)) as «class utf8»
  tell application "Notes" to set body of note id (item 1 of argv) to htmlBody
end run
AS
  sleep 3; echo "-- after update $k:"; report "$id9"
done
echo "-- body V9 after updates:"; dump "$id9"
echo "== V8 update existing V1 note body again (does the image survive / duplicate?)"
if [ -n "${ID1:-}" ]; then
  osa - "$ID1" "$OUT/v1.html" <<'AS'
on run argv
  set htmlBody to read (POSIX file (item 2 of argv)) as «class utf8»
  tell application "Notes" to set body of note id (item 1 of argv) to htmlBody
end run
AS
  sleep 4; report "$ID1"
fi
echo "== done"
