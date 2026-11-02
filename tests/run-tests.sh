#!/bin/bash
# Runs mac-cleanup.sh against a throwaway home folder, with every external tool
# that could change the real machine (uv, npm, xcrun) replaced by a stub.

set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/mac-cleanup.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
STUBS="$WORK/stubs"
CALLS="$WORK/calls.log"
fails=0

check() {
  if eval "$2"; then echo "ok    $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi
}

mkdir -p "$STUBS"
for tool in npm xcrun; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$tool" "$CALLS" > "$STUBS/$tool"
done
printf '#!/bin/bash\nif [ "$1" = "cache" ] && [ "$2" = "dir" ]; then echo "$HOME/.cache/uv"; else echo "uv $*" >> "%s"; fi\n' "$CALLS" > "$STUBS/uv"
printf '#!/bin/bash\necho /fake/developer\n' > "$STUBS/xcode-select"
printf '#!/bin/bash\nexit 1\n' > "$STUBS/defaults"
# Files with "opened" in the name look recently opened to Spotlight.
cat > "$STUBS/mdls" <<'EOF'
#!/bin/bash
case "$*" in
  *opened*) date -u '+%Y-%m-%d %H:%M:%S +0000' ;;
  *) echo '(null)' ;;
esac
EOF
chmod +x "$STUBS"/*

build_home() {
  rm -rf "$FAKE_HOME"; : > "$CALLS"
  mkdir -p "$FAKE_HOME/Library/Caches/SomeApp" "$FAKE_HOME/Library/Caches/ms-playwright" \
    "$FAKE_HOME/Library/Caches/com.apple.Safari" "$FAKE_HOME/Library/Logs" \
    "$FAKE_HOME/Library/Developer/Xcode/DerivedData/Proj" "$FAKE_HOME/.gradle/caches/x" \
    "$FAKE_HOME/.cache/uv" "$FAKE_HOME/.cache/huggingface" "$FAKE_HOME/Downloads" "$FAKE_HOME/.Trash" \
    "$WORK/outside"
  echo data > "$FAKE_HOME/Library/Caches/SomeApp/file"
  echo data > "$FAKE_HOME/Library/Caches/.hidden"
  echo data > "$FAKE_HOME/Library/Caches/ms-playwright/browser"
  echo data > "$FAKE_HOME/Library/Caches/com.apple.Safari/file"
  echo data > "$FAKE_HOME/.cache/huggingface/model"
  echo data > "$FAKE_HOME/Downloads/app one.dmg"
  echo data > "$FAKE_HOME/Downloads/tool.PKG"
  echo data > "$FAKE_HOME/Downloads/contract.pdf"
  echo data > "$FAKE_HOME/Downloads/photos.zip"
  echo data > "$FAKE_HOME/Library/Logs/old.log"
  echo data > "$FAKE_HOME/Library/Logs/new.log"
  touch -t 202001010000 "$FAKE_HOME/Library/Logs/old.log"
  echo keep > "$WORK/outside/precious"
  ln -s "$WORK/outside" "$FAKE_HOME/Library/Caches/link-out"
}

run() { HOME="$FAKE_HOME" PATH="$STUBS:$PATH" bash "$SCRIPT" "$@"; }

snapshot() { (cd "$FAKE_HOME" && find . | sort); }

build_home
before="$(snapshot)"
run clean > "$WORK/out.txt" 2>&1
check "dry run exits 0" "[ $? -eq 0 ]"
check "dry run changes no file" '[ "$before" = "$(snapshot)" ]'
check "dry run calls no tool that deletes" '! grep -qE "clean|delete" "$CALLS"'
check "dry run says so" 'grep -q "Dry run" "$WORK/out.txt"'

run clean --apply > /dev/null 2>&1
check "--apply without categories is refused" "[ $? -eq 2 ]"
check "refused apply changes no file" '[ "$before" = "$(snapshot)" ]'

run clean --apply nonsense > /dev/null 2>&1
check "unknown category is refused" "[ $? -eq 2 ]"
run clean --force uv > /dev/null 2>&1
check "unknown option is refused" "[ $? -eq 2 ]"

run clean --apply user-caches > /dev/null 2>&1
check "cache folder removed" '[ ! -e "$FAKE_HOME/Library/Caches/SomeApp" ]'
check "hidden cache removed" '[ ! -e "$FAKE_HOME/Library/Caches/.hidden" ]'
check "playwright kept" '[ -e "$FAKE_HOME/Library/Caches/ms-playwright/browser" ]'
check "com.apple cache kept" '[ -e "$FAKE_HOME/Library/Caches/com.apple.Safari/file" ]'
check "symlink target outside home survives" '[ -e "$WORK/outside/precious" ]'
check "other categories untouched" '[ -e "$FAKE_HOME/Downloads/app one.dmg" ] && [ -e "$FAKE_HOME/.gradle/caches/x" ]'
check "models untouched" '[ -e "$FAKE_HOME/.cache/huggingface/model" ]'

build_home
run clean --apply installers > /dev/null 2>&1
check "dmg moved to Trash" '[ -e "$FAKE_HOME/.Trash/app one.dmg" ] && [ ! -e "$FAKE_HOME/Downloads/app one.dmg" ]'
check "uppercase PKG moved to Trash" '[ -e "$FAKE_HOME/.Trash/tool.PKG" ]'
check "pdf and zip stay" '[ -e "$FAKE_HOME/Downloads/contract.pdf" ] && [ -e "$FAKE_HOME/Downloads/photos.zip" ]'

echo data > "$FAKE_HOME/Downloads/app one.dmg"
run clean --apply installers > /dev/null 2>&1
check "same name in Trash is not overwritten" '[ "$(find "$FAKE_HOME/.Trash" -name "*app one.dmg" | wc -l)" -eq 2 ]'

build_home
run clean --apply old-logs gradle xcode-derived-data > /dev/null 2>&1
check "old log removed" '[ ! -e "$FAKE_HOME/Library/Logs/old.log" ]'
check "recent log kept" '[ -e "$FAKE_HOME/Library/Logs/new.log" ]'
check "gradle cache removed" '[ ! -e "$FAKE_HOME/.gradle/caches" ]'
check "derived data removed" '[ ! -e "$FAKE_HOME/Library/Developer/Xcode/DerivedData" ]'

build_home
run clean --apply uv npm simulators-unavailable > /dev/null 2>&1
check "uv uses its own command" 'grep -q "uv cache clean" "$CALLS"'
check "npm uses its own command" 'grep -q "npm cache clean --force" "$CALLS"'
check "simulators use simctl" 'grep -q "xcrun simctl delete unavailable" "$CALLS"'

build_home
before="$(snapshot)"
: > "$CALLS"
run analyze > "$WORK/analyze.txt" 2>&1
check "analyze exits 0" "[ $? -eq 0 ]"
check "analyze changes no file" '[ "$before" = "$(snapshot)" ]'
check "analyze reports coverage" 'grep -q "Coverage" "$WORK/analyze.txt"'
check "analyze prints no bash error" '! grep -qE "unbound variable|syntax error|command not found" "$WORK/analyze.txt"'

old_file() { mkdir -p "$(dirname "$1")"; echo "${2:-data}" > "$1"; touch -t 202001010000 "$1"; }

build_home
old_file "$FAKE_HOME/Desktop/Screenshot 2020-01-01.png"
old_file "$FAKE_HOME/Desktop/Captura de Tela 2020.png"
old_file "$FAKE_HOME/Desktop/Screenshot opened.png"
old_file "$FAKE_HOME/Desktop/Screenshot notes.txt"
old_file "$FAKE_HOME/Desktop/holiday.png"
old_file "$FAKE_HOME/Desktop/Projects/Screenshot deep.png"
echo data > "$FAKE_HOME/Desktop/Screenshot new.png"
old_file "$FAKE_HOME/Downloads/ScreenRecording_old.MP4"
old_file "$FAKE_HOME/Downloads/report.pdf" same
old_file "$FAKE_HOME/Downloads/report (1).pdf" same
old_file "$FAKE_HOME/Downloads/notes.pdf" one
old_file "$FAKE_HOME/Downloads/notes (1).pdf" two
old_file "$FAKE_HOME/Documents/Work.zip"
mkdir -p "$FAKE_HOME/Documents/Work"
before="$(snapshot)"
run forgotten > "$WORK/forgotten.txt" 2>&1
check "forgotten exits 0" "[ $? -eq 0 ]"
check "forgotten changes no file" '[ "$before" = "$(snapshot)" ]'
check "forgotten lists old screenshot" 'grep -q "Screenshot 2020-01-01.png" "$WORK/forgotten.txt"'
check "forgotten lists zip beside its folder" 'grep -q "Work.zip" "$WORK/forgotten.txt"'
check "forgotten prints no bash error" '! grep -qE "unbound variable|syntax error|command not found" "$WORK/forgotten.txt"'

run clean --apply old-screenshots old-recordings duplicate-downloads > /dev/null 2>&1
check "old screenshot in Trash" '[ -e "$FAKE_HOME/.Trash/Screenshot 2020-01-01.png" ]'
check "pt-BR screenshot in Trash" '[ -e "$FAKE_HOME/.Trash/Captura de Tela 2020.png" ]'
check "recently opened screenshot stays" '[ -e "$FAKE_HOME/Desktop/Screenshot opened.png" ]'
check "new screenshot stays" '[ -e "$FAKE_HOME/Desktop/Screenshot new.png" ]'
check "non-image named Screenshot stays" '[ -e "$FAKE_HOME/Desktop/Screenshot notes.txt" ]'
check "other picture stays" '[ -e "$FAKE_HOME/Desktop/holiday.png" ]'
check "screenshot in a project folder stays" '[ -e "$FAKE_HOME/Desktop/Projects/Screenshot deep.png" ]'
check "old recording in Trash" '[ -e "$FAKE_HOME/.Trash/ScreenRecording_old.MP4" ]'
check "exact copy in Trash, original stays" '[ -e "$FAKE_HOME/.Trash/report (1).pdf" ] && [ -e "$FAKE_HOME/Downloads/report.pdf" ]'
check "same name with other content stays" '[ -e "$FAKE_HOME/Downloads/notes (1).pdf" ]'
check "zip is never moved by a category" '[ -e "$FAKE_HOME/Documents/Work.zip" ]'

build_home
old_file "$FAKE_HOME/Downloads/Pngtree-coffee_123.png"
old_file "$FAKE_HOME/Desktop/vecteezy_cup_456.png"
old_file "$FAKE_HOME/Downloads/opened Pngtree.png"
old_file "$FAKE_HOME/Downloads/Project/Pngtree-part.png"
old_file "$FAKE_HOME/Documents/Pngtree-kept.png"
echo data > "$FAKE_HOME/Downloads/Pngtree-new.png"
for keep in "Lucas Spain Passport.jpg" "Payslip - 2025.pdf" "Statement_2025_10.pdf" "Signed-Renewal 2025.pdf" \
  "Pos Operatorio.pdf" "Certificate.pdf" "front.JPG" "IMG_1197.HEIC" "Lucas CV.pdf" "Untitled design.mp4"; do
  old_file "$FAKE_HOME/Downloads/$keep"
done
run forgotten > "$WORK/forgotten-web.txt" 2>&1
check "paperwork is listed as pick-only" 'sed -n "/^Other loose files/,/^$/p" "$WORK/forgotten-web.txt" | grep -q "Passport"'
check "paperwork is not in the category list" '! sed -n "/^Stock and web files/,/^$/p" "$WORK/forgotten-web.txt" | grep -qE "Passport|Payslip"'
run clean --apply unopened-web-files > /dev/null 2>&1
check "old stock file in Downloads goes to Trash" '[ -e "$FAKE_HOME/.Trash/Pngtree-coffee_123.png" ] && [ ! -e "$FAKE_HOME/Downloads/Pngtree-coffee_123.png" ]'
check "old stock file on Desktop goes to Trash" '[ -e "$FAKE_HOME/.Trash/vecteezy_cup_456.png" ]'
check "recently opened stock file stays" '[ -e "$FAKE_HOME/Downloads/opened Pngtree.png" ]'
check "new stock file stays" '[ -e "$FAKE_HOME/Downloads/Pngtree-new.png" ]'
check "file inside a folder stays" '[ -e "$FAKE_HOME/Downloads/Project/Pngtree-part.png" ]'
check "Documents stays" '[ -e "$FAKE_HOME/Documents/Pngtree-kept.png" ]'
for keep in "Lucas Spain Passport.jpg" "Payslip - 2025.pdf" "Statement_2025_10.pdf" "Signed-Renewal 2025.pdf" \
  "Pos Operatorio.pdf" "Certificate.pdf" "front.JPG" "IMG_1197.HEIC" "Lucas CV.pdf" "Untitled design.mp4"; do
  check "old personal file stays: $keep" "[ -e \"$FAKE_HOME/Downloads/$keep\" ] && [ ! -e \"$FAKE_HOME/.Trash/$keep\" ]"
done

build_home
rm -f "$FAKE_HOME"/Downloads/*
run clean old-screenshots duplicate-downloads installers > "$WORK/empty.txt" 2>&1
check "empty lists measure zero, not the current folder" 'grep -q "Total: 0 KB" "$WORK/empty.txt"'

build_home
old_file "$FAKE_HOME/Documents/pick.txt"
run trash "$FAKE_HOME/Documents/pick.txt" > /dev/null 2>&1
check "trash moves a chosen file" "[ $? -eq 0 ] && [ -e \"$FAKE_HOME/.Trash/pick.txt\" ]"
for bad in "$FAKE_HOME/Documents" "$FAKE_HOME/Library/Caches/SomeApp" "$FAKE_HOME/.cache/huggingface/model" \
  "$FAKE_HOME/Documents/../Downloads/contract.pdf" "$WORK/outside/precious" "$FAKE_HOME"; do
  run trash "$bad" > /dev/null 2>&1
  rc=$?
  check "trash refuses $(basename "$bad")" "[ $rc -ne 0 ] && [ -e \"$bad\" ]"
done

run speed > "$WORK/speed.txt" 2>&1
check "speed exits 0" "[ $? -eq 0 ]"
check "speed prints no bash error" '! grep -qE "unbound variable|syntax error|command not found" "$WORK/speed.txt"'

HOME=/ bash "$SCRIPT" clean --apply user-caches > /dev/null 2>&1
check "HOME=/ is refused" "[ $? -eq 2 ]"

echo
if [ "$fails" -eq 0 ]; then echo "all tests passed"; else echo "$fails test(s) failed"; exit 1; fi
