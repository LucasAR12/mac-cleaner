#!/bin/bash
# mac-cleaner: measure disk use on macOS and remove only what can be rebuilt.
#
#   mac-cleanup.sh analyze                     read-only report
#   mac-cleanup.sh clean                       dry run of every category
#   mac-cleanup.sh clean <category>...         dry run of those categories
#   mac-cleanup.sh clean --apply <category>... really clean those categories
#   mac-cleanup.sh forgotten [--all]           list forgotten personal files
#   mac-cleanup.sh trash <path>...             move chosen files to the Trash
#   mac-cleanup.sh speed                       read-only memory and startup report
#
# Works with the Bash 3.2 that ships with macOS. It never uses sudo, never
# empties the Trash and never touches anything outside the user's home folder.
# Personal files only ever move to the Trash, so they can be put back.

set -u
export LC_ALL=C
shopt -s nullglob

CATEGORIES="user-caches installers uv npm gradle xcode-derived-data simulators-unavailable old-logs"
PERSONAL_CATEGORIES="old-screenshots old-recordings duplicate-downloads unopened-files"
LOG_AGE_DAYS=7
MEDIA_AGE_DAYS=90
FORGOTTEN_DAYS=180
LARGE_FILE_MB=500
LIST_LIMIT=15

die() { echo "error: $*" >&2; exit 2; }

[ -n "${HOME:-}" ] && [ "$HOME" != "/" ] && [ -d "$HOME" ] || die "HOME is not a usable folder"

human() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576) printf "%.1f GB", kb / 1048576
    else if (kb >= 1024) printf "%.0f MB", kb / 1024
    else printf "%d KB", kb
  }'
}

size_kb() {
  [ -e "$1" ] || { echo 0; return; }
  du -sk "$1" 2>/dev/null | awk 'END { print $1 + 0 }'
}

data_volume() {
  if [ -d /System/Volumes/Data ]; then echo /System/Volumes/Data; else echo /; fi
}

free_kb() { df -k "$(data_volume)" | awk 'END { print $4 }'; }
used_kb() { df -k "$(data_volume)" | awk 'END { print $3 }'; }

# Refuses any path outside the home folder, whatever the caller computed.
safe_rm() {
  case "$1" in
    "$HOME"/?*) rm -rf -- "$1" 2>/dev/null ;;
    *) echo "  refused: $1" >&2; return 1 ;;
  esac
}

# Protected by macOS (rm fails with "Operation not permitted") or expensive to
# get back: browser binaries used by test tools are not really a cache.
is_kept_cache() {
  case "$1" in
    com.apple.*|CloudKit|FamilyCircle|familycircled|ms-playwright|Cypress|puppeteer) return 0 ;;
    *) return 1 ;;
  esac
}

cache_entries() {
  local entry
  for entry in "$HOME/Library/Caches"/* "$HOME/Library/Caches"/.[!.]*; do
    is_kept_cache "$(basename "$entry")" || printf '%s\0' "$entry"
  done
}

installer_files() {
  [ -d "$HOME/Downloads" ] || return 0
  find "$HOME/Downloads" -maxdepth 1 \( -iname '*.dmg' -o -iname '*.pkg' \) -print0 2>/dev/null
}

sum_du() { xargs -0 du -sk 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'; }

old_log_kb() {
  [ -d "$HOME/Library/Logs" ] || { echo 0; return; }
  find "$HOME/Library/Logs" -type f -mtime +"$LOG_AGE_DAYS" -exec du -k {} + 2>/dev/null \
    | awk '{ s += $1 } END { print s + 0 }'
}

has_xcode_tools() { xcode-select -p >/dev/null 2>&1 && command -v xcrun >/dev/null 2>&1; }

unavailable_simulators() {
  has_xcode_tools || { echo 0; return; }
  xcrun simctl list devices unavailable 2>/dev/null | grep -c '(unavailable' || true
}

uv_cache_dir() {
  command -v uv >/dev/null 2>&1 && uv cache dir 2>/dev/null
}

capture_folders() {
  local custom
  printf '%s\n' "$HOME/Desktop" "$HOME/Downloads"
  custom="$(defaults read com.apple.screencapture location 2>/dev/null)"
  custom="${custom/#\~/$HOME}"
  case "$custom" in
    "$HOME/Desktop"|"$HOME/Downloads") ;;
    "$HOME"/*) [ -d "$custom" ] && printf '%s\n' "$custom" ;;
  esac
}

# Spotlight knows when a file was last opened, which the modified date does not.
opened_within_days() {
  local used used_s limit_s
  used="$(mdls -raw -name kMDItemLastUsedDate "$1" 2>/dev/null)"
  case "$used" in ''|'(null)') return 1 ;; esac
  used_s="$(date -u -j -f '%Y-%m-%d %H:%M:%S +0000' "$used" +%s 2>/dev/null)" || return 1
  limit_s=$(( $(date +%s) - $2 * 86400 ))
  [ "$used_s" -ge "$limit_s" ]
}

drop_recently_opened() {
  local entry
  while IFS= read -r -d '' entry; do
    opened_within_days "$entry" "$1" || printf '%s\0' "$entry"
  done
}

# macOS stores accented names decomposed, so patterns use * in place of accents.
screenshot_files() {
  local folder
  capture_folders | while IFS= read -r folder; do
    [ -d "$folder" ] || continue
    find "$folder" -maxdepth 1 -type f -mtime +"$MEDIA_AGE_DAYS" \
      \( -iname 'Screenshot*' -o -iname 'Screen Shot*' -o -iname 'Captura de Tela*' -o -iname 'Captura de ecr*' -o -iname 'CleanShot*' \) \
      \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.tiff' \) -print0 2>/dev/null
  done | drop_recently_opened "$MEDIA_AGE_DAYS"
}

recording_files() {
  local folder
  capture_folders | while IFS= read -r folder; do
    [ -d "$folder" ] || continue
    find "$folder" -maxdepth 1 -type f -mtime +"$MEDIA_AGE_DAYS" \
      \( -iname 'Screen Recording*' -o -iname 'ScreenRecording*' -o -iname 'Grava*o de Tela*' -o -iname 'Grava*o do ecr*' \) \
      \( -iname '*.mov' -o -iname '*.mp4' \) -print0 2>/dev/null
  done | drop_recently_opened "$MEDIA_AGE_DAYS"
}

# Only exact copies: "file (1).pdf" counts when "file.pdf" has the same bytes.
duplicate_downloads() {
  local entry original
  [ -d "$HOME/Downloads" ] || return 0
  while IFS= read -r -d '' entry; do
    original="$(printf '%s' "$entry" | sed -E 's/ ?\([0-9]+\)(\.[^.\/]*)?$/\1/')"
    [ "$original" != "$entry" ] && [ -f "$original" ] && cmp -s "$entry" "$original" && printf '%s\0' "$entry"
  done < <(find "$HOME/Downloads" -maxdepth 1 -type f -name '*([0-9]*)*' -print0 2>/dev/null)
}

forgotten_downloads() {
  [ -d "$HOME/Downloads" ] || return 0
  find "$HOME/Downloads" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -mtime +"$FORGOTTEN_DAYS" -print0 2>/dev/null \
    | drop_recently_opened "$FORGOTTEN_DAYS"
}

# Loose files only: taking one file out of a folder could break a project, and
# Documents is left out because paperwork can sit unopened for years and matter.
unopened_files() {
  local folder
  for folder in "$HOME/Desktop" "$HOME/Downloads"; do
    [ -d "$folder" ] || continue
    find "$folder" -maxdepth 1 -type f ! -name '.*' -mtime +"$FORGOTTEN_DAYS" -print0 2>/dev/null
  done | drop_recently_opened "$FORGOTTEN_DAYS"
}

unopened_documents() {
  [ -d "$HOME/Documents" ] || return 0
  find "$HOME/Documents" -mindepth 1 -maxdepth 1 ! -name '.*' -mtime +"$FORGOTTEN_DAYS" -print0 2>/dev/null \
    | drop_recently_opened "$FORGOTTEN_DAYS"
}

personal_files() {
  case "$1" in
    old-screenshots) screenshot_files ;;
    old-recordings) recording_files ;;
    duplicate-downloads) duplicate_downloads ;;
    unopened-files) unopened_files ;;
  esac
}

large_forgotten_files() {
  find "$HOME" \( -path "$HOME/Library" -o -path "$HOME/.*" -o -name node_modules \) -prune -o \
    -type f -size +"$LARGE_FILE_MB"M -mtime +"$FORGOTTEN_DAYS" -print0 2>/dev/null \
    | drop_recently_opened "$FORGOTTEN_DAYS"
}

# "Work.zip" next to a "Work" folder: probably already unpacked, but not proven.
unpacked_archives() {
  local folder entry
  for folder in "$HOME/Downloads" "$HOME/Documents" "$HOME/Desktop"; do
    for entry in "$folder"/*.zip; do
      [ -d "${entry%.zip}" ] && printf '%s\0' "$entry"
    done
  done
}

unused_apps() {
  local app
  for app in /Applications/*.app; do
    mdls -raw -name kMDItemLastUsedDate "$app" 2>/dev/null | grep -q '^[0-9]' || continue
    opened_within_days "$app" "$FORGOTTEN_DAYS" || printf '%s\0' "$app"
  done
}

print_list() {
  local title="$1" entry kb tmp count=0 total=0
  tmp="$(mktemp)"
  while IFS= read -r -d '' entry; do
    kb="$(size_kb "$entry")"
    count=$((count + 1))
    total=$((total + kb))
    printf '%s\t%s\t%s\n' "$kb" "$(stat -f '%Sm' -t '%Y-%m-%d' "$entry" 2>/dev/null)" "$entry" >> "$tmp"
  done
  if [ "$count" -gt 0 ]; then
    echo
    echo "$title: $count, $(human "$total")"
    sort -rn "$tmp" | head -"$LIST_LIMIT" | while IFS=$'\t' read -r kb entry_date entry; do
      printf '  %10s  %s  %s\n' "$(human "$kb")" "$entry_date" "$entry"
    done
    [ "$count" -le "$LIST_LIMIT" ] || echo "  ...and $((count - LIST_LIMIT)) more (use --all)"
  fi
  rm -f "$tmp"
}

cmd_forgotten() {
  case "${1:-}" in
    --all) LIST_LIMIT=100000 ;;
    '') ;;
    *) die "forgotten only takes --all" ;;
  esac
  echo "Nothing here was changed. Dates are when each file was last modified."
  screenshot_files | print_list "Screenshots older than $MEDIA_AGE_DAYS days (category: old-screenshots)"
  recording_files | print_list "Screen recordings older than $MEDIA_AGE_DAYS days (category: old-recordings)"
  duplicate_downloads | print_list "Exact copies in Downloads (category: duplicate-downloads)"
  unopened_files | print_list "Loose files on Desktop and in Downloads not opened for $FORGOTTEN_DAYS days (category: unopened-files)"
  forgotten_downloads | print_list "Folders in Downloads untouched for $FORGOTTEN_DAYS days (pick with: trash <path>)"
  unopened_documents | print_list "Items in Documents untouched for $FORGOTTEN_DAYS days; check before removing (pick with: trash <path>)"
  large_forgotten_files | print_list "Files over $LARGE_FILE_MB MB untouched for $FORGOTTEN_DAYS days (pick with: trash <path>)"
  unpacked_archives | print_list "Zip files next to a folder of the same name; check the folder is complete (pick with: trash <path>)"
  unused_apps | print_list "Apps not opened for $FORGOTTEN_DAYS days (uninstall them yourself)"
}

cmd_trash() {
  local path failed=0
  [ "$#" -gt 0 ] || die "trash needs at least one full path"
  mkdir -p "$HOME/.Trash" 2>/dev/null
  for path in "$@"; do
    # The depth rule protects ~/Documents and the like as a whole.
    case "$path" in
      */../*|*/..|"$HOME/Library"/*|"$HOME/.Trash"/*|"$HOME"/.*) echo "refused: $path"; failed=1; continue ;;
      "$HOME"/?*/?*) ;;
      *) echo "refused: $path"; failed=1; continue ;;
    esac
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then echo "not found: $path"; failed=1; continue; fi
    if move_to_trash "$path"; then echo "moved to the Trash: $path"; else echo "could not move: $path"; failed=1; fi
  done
  return "$failed"
}

cmd_speed() {
  local mem_kb swap agents
  mem_kb=$(( $(sysctl -n hw.memsize) / 1024 ))
  swap="$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+[A-Z]).*/\1/')"
  echo "Memory"
  echo "  Installed: $(human "$mem_kb"). Swap in use: $swap."
  memory_pressure -Q 2>/dev/null | grep -i 'percentage' | sed 's/^/  /'
  echo "  Swap of several GB means memory is short; closing the apps below helps more than freeing disk."
  echo
  echo "Apps using the most memory right now"
  ps -axo rss=,comm= | awk '{
      rss = $1; line = $0
      if (match(line, /[^\/]+\.app\//)) name = substr(line, RSTART, RLENGTH - 5)
      else { n = split(line, parts, "/"); name = parts[n]; sub(/^ *[0-9]+ */, "", name) }
      total[name] += rss
    } END { for (name in total) printf "%d\t%s\n", total[name], name }' | sort -rn | head -8 \
    | while IFS=$'\t' read -r kb name; do printf '  %10s  %s\n' "$(human "$kb")" "$name"; done
  echo
  echo "Programs that start on their own, apart from Apple's"
  agents="$(ls "$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons 2>/dev/null | grep '\.plist$' | grep -v '^com\.apple\.' | sed 's/\.plist$//' | sort -u)"
  if [ -n "$agents" ]; then echo "$agents" | sed 's/^/  /'; else echo "  none"; fi
  echo "  Turn them off in: System Settings > General > Login Items & Extensions."
}

category_kb() {
  local dir
  case "$1" in
    old-screenshots|old-recordings|duplicate-downloads|unopened-files) personal_files "$1" | sum_du ;;
    user-caches) cache_entries | sum_du ;;
    installers) installer_files | sum_du ;;
    uv) dir="$(uv_cache_dir)"; if [ -n "$dir" ]; then size_kb "$dir"; else echo 0; fi ;;
    npm) size_kb "$HOME/.npm/_cacache" ;;
    gradle) size_kb "$HOME/.gradle/caches" ;;
    xcode-derived-data) size_kb "$HOME/Library/Developer/Xcode/DerivedData" ;;
    simulators-unavailable) echo 0 ;;
    old-logs) old_log_kb ;;
  esac
}

category_note() {
  case "$1" in
    old-screenshots) echo "not opened for $MEDIA_AGE_DAYS days; moved to the Trash, list them with: forgotten" ;;
    old-recordings) echo "not opened for $MEDIA_AGE_DAYS days; moved to the Trash, list them with: forgotten" ;;
    duplicate-downloads) echo "exact copies like 'file (1).pdf'; moved to the Trash" ;;
    unopened-files) echo "loose files on Desktop and in Downloads not opened for $FORGOTTEN_DAYS days; moved to the Trash" ;;
    user-caches) echo "app caches; apps rebuild them, first launch is slower" ;;
    installers) echo ".dmg/.pkg in Downloads; moved to the Trash, not deleted" ;;
    uv) echo "Python packages; downloaded again when needed" ;;
    npm) echo "Node packages; downloaded again when needed" ;;
    gradle) echo "Android/Java build cache; next build is slower" ;;
    xcode-derived-data) echo "Xcode build output; next build is slower" ;;
    simulators-unavailable) echo "$(unavailable_simulators) simulator(s) no longer usable by any Xcode" ;;
    old-logs) echo "log files older than $LOG_AGE_DAYS days" ;;
  esac
}

move_to_trash() {
  local name target
  name="$(basename "$1")"
  target="$HOME/.Trash/$name"
  [ -e "$target" ] && target="$HOME/.Trash/$(date +%Y%m%d-%H%M%S)-$name"
  mv -- "$1" "$target" 2>/dev/null
}

warn_open_apps() {
  local app
  for app in "Google Chrome" "Brave Browser" "Safari" "firefox" "Slack" "Spotify"; do
    if pgrep -x "$app" >/dev/null 2>&1; then
      echo "  note: $app is open and will keep writing to its cache"
    fi
  done
}

clean_category() {
  local entry failed=0
  case "$1" in
    user-caches)
      warn_open_apps
      while IFS= read -r -d '' entry; do
        safe_rm "$entry" || failed=$((failed + 1))
      done < <(cache_entries)
      ;;
    installers)
      mkdir -p "$HOME/.Trash" 2>/dev/null
      while IFS= read -r -d '' entry; do
        move_to_trash "$entry" || failed=$((failed + 1))
      done < <(installer_files)
      ;;
    old-screenshots|old-recordings|duplicate-downloads|unopened-files)
      mkdir -p "$HOME/.Trash" 2>/dev/null
      while IFS= read -r -d '' entry; do
        move_to_trash "$entry" || failed=$((failed + 1))
      done < <(personal_files "$1")
      ;;
    uv)
      if command -v uv >/dev/null 2>&1; then uv cache clean >/dev/null 2>&1 || failed=1
      else echo "  skipped: uv is not installed"; fi
      ;;
    npm)
      if command -v npm >/dev/null 2>&1; then npm cache clean --force >/dev/null 2>&1 || failed=1
      else echo "  skipped: npm is not installed"; fi
      ;;
    gradle) safe_rm "$HOME/.gradle/caches" || failed=1 ;;
    xcode-derived-data) safe_rm "$HOME/Library/Developer/Xcode/DerivedData" || failed=1 ;;
    simulators-unavailable)
      if has_xcode_tools; then xcrun simctl delete unavailable >/dev/null 2>&1 || failed=1
      else echo "  skipped: Xcode tools are not installed"; fi
      ;;
    old-logs)
      [ -d "$HOME/Library/Logs" ] && find "$HOME/Library/Logs" -type f -mtime +"$LOG_AGE_DAYS" -delete 2>/dev/null
      ;;
  esac
  # A busy app can recreate files mid-delete; that is expected, so report it
  # and keep going instead of aborting the rest of the clean.
  [ "$failed" -eq 0 ] || echo "  note: $failed item(s) could not be removed (in use or protected)"
}

cmd_clean() {
  local apply=0 selected="" arg cat kb total=0 before after
  for arg in "$@"; do
    case "$arg" in
      --apply) apply=1 ;;
      -*) die "unknown option: $arg" ;;
      *)
        case " $CATEGORIES $PERSONAL_CATEGORIES " in
          *" $arg "*) selected="$selected $arg" ;;
          *) die "unknown category: $arg (choose from: $CATEGORIES $PERSONAL_CATEGORIES)" ;;
        esac
        ;;
    esac
  done
  if [ "$apply" -eq 1 ] && [ -z "$selected" ]; then
    die "--apply needs the categories named one by one (choose from: $CATEGORIES $PERSONAL_CATEGORIES)"
  fi
  [ -n "$selected" ] || selected="$CATEGORIES $PERSONAL_CATEGORIES"

  before="$(free_kb)"
  if [ "$apply" -eq 1 ]; then echo "Cleaning:"; else echo "Dry run, nothing will change:"; fi
  for cat in $selected; do
    kb="$(category_kb "$cat")"
    total=$((total + kb))
    printf '  %-24s %10s  %s\n' "$cat" "$(human "$kb")" "$(category_note "$cat")"
    [ "$apply" -eq 1 ] && clean_category "$cat"
  done
  echo
  if [ "$apply" -eq 1 ]; then
    after="$(free_kb)"
    echo "Free space: $(human "$before") before, $(human "$after") now."
    echo "macOS also frees purgeable space on its own, so the change may not match the sizes above."
  else
    echo "Total: $(human "$total"). To clean, run: clean --apply <category>..."
  fi
}

print_review_item() {
  local kb
  kb="$(size_kb "$2")"
  [ "$kb" -gt 102400 ] || return 0
  printf '  %-24s %10s  %s\n' "$1" "$(human "$kb")" "$3"
}

cmd_analyze() {
  local cat kb total=0 measured used gap trash_ok=1 dupes snapshots
  echo "Disk"
  df -h "$(data_volume)" | awk 'END { printf "  size %s, used %s, free %s (%s full)\n", $2, $3, $4, $5 }'

  if [ -e "$HOME/.Trash" ] && ! ls "$HOME/.Trash" >/dev/null 2>&1; then trash_ok=0; fi

  echo
  echo "Safe to clean (rebuilt automatically)"
  for cat in $CATEGORIES; do
    kb="$(category_kb "$cat")"
    total=$((total + kb))
    printf '  %-24s %10s  %s\n' "$cat" "$(human "$kb")" "$(category_note "$cat")"
  done
  echo "  Total: $(human "$total")"

  echo
  echo "Review first (only items over 100 MB; remove through the app named)"
  print_review_item "Android emulators" "$HOME/.android/avd" "Android Studio > Device Manager; emulator data is lost"
  print_review_item "Android SDK" "$HOME/Library/Android/sdk" "needed by Android Studio; drop old system images in SDK Manager"
  print_review_item "iOS simulators" "$HOME/Library/Developer/CoreSimulator/Devices" "Xcode > Devices and Simulators; simulator data is lost"
  print_review_item "iOS device support" "$HOME/Library/Developer/Xcode/iOS DeviceSupport" "Xcode rebuilds it when a device connects"
  print_review_item "iPhone backups" "$HOME/Library/Application Support/MobileSync/Backup" "Finder > iPhone > Manage Backups; may be your only copy"
  print_review_item "Steam games" "$HOME/Library/Application Support/Steam/steamapps/common" "Steam > Uninstall; downloaded again if wanted"
  print_review_item "Hugging Face models" "$HOME/.cache/huggingface" "used by local AI tools; delete only models no longer used"
  print_review_item "Ollama models" "$HOME/.ollama/models" "ollama rm <model>"
  print_review_item "LM Studio models" "$HOME/.lmstudio/models" "LM Studio > My Models"
  print_review_item "Docker" "$HOME/Library/Containers/com.docker.docker" "docker system prune; images and volumes may hold work"
  print_review_item "Parallels VMs" "$HOME/Parallels" "Parallels > Reclaim Disk Space; deleting loses the VM"
  print_review_item "Claude Desktop VM" "$HOME/Library/Application Support/Claude/vm_bundles" "in use by the Claude app; leave it"
  print_review_item "Trash" "$HOME/.Trash" "empty it in Finder once you are sure"

  dupes="$(ls /Applications 2>/dev/null | sed -nE 's/ 20[0-9]{2}(\.app)?$//p' | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    echo
    echo "Apps with more than one yearly version installed"
    echo "$dupes" | sed 's/^/  /'
  fi

  snapshots="$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple' || true)"
  if [ "${snapshots:-0}" -gt 0 ]; then
    echo
    echo "Time Machine: $snapshots local snapshot(s). macOS deletes them when space runs low."
  fi

  echo
  echo "Largest folders in your home"
  du -sk "$HOME"/* "$HOME"/.[!.]* 2>/dev/null | sort -rn | head -10 \
    | while IFS=$'\t' read -r kb path; do printf '  %10s  %s\n' "$(human "$kb")" "${path#"$HOME"/}"; done

  echo
  echo "Largest apps"
  du -sk /Applications/* 2>/dev/null | sort -rn | head -5 \
    | while IFS=$'\t' read -r kb path; do printf '  %10s  %s\n' "$(human "$kb")" "${path#/Applications/}"; done

  # Compare what du could see with what the disk reports, so a report with big
  # blind spots does not pass as complete.
  measured=$(( $(size_kb "$HOME") + $(size_kb /Applications) + $(size_kb /Library) ))
  used="$(used_kb)"
  gap=$((used - measured))
  echo
  echo "Coverage"
  echo "  Measured about $(human "$measured") of $(human "$used") in use."
  if [ "$gap" -gt 5242880 ]; then
    echo "  About $(human "$gap") was not seen: system files, snapshots, or folders macOS keeps private."
  fi
  if [ "$trash_ok" -eq 0 ]; then
    echo "  Full Disk Access is off, so the Trash, Mail and app containers read as small or empty."
    echo "  To see them: System Settings > Privacy & Security > Full Disk Access, add your terminal, reopen it."
  fi
  echo
  echo "Next: 'forgotten' lists old screenshots and files not opened in 6 months; 'speed' shows memory and startup programs."
}

case "${1:-}" in
  analyze) shift; [ "$#" -eq 0 ] || die "analyze takes no arguments"; cmd_analyze ;;
  clean) shift; cmd_clean "$@" ;;
  forgotten) shift; cmd_forgotten "$@" ;;
  trash) shift; cmd_trash "$@" ;;
  speed) shift; [ "$#" -eq 0 ] || die "speed takes no arguments"; cmd_speed ;;
  *)
    echo "usage: mac-cleanup.sh analyze | clean [--apply] [category...] | forgotten [--all] | trash <path>... | speed"
    echo "categories: $CATEGORIES $PERSONAL_CATEGORIES"
    exit 2
    ;;
esac
