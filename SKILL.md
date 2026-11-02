---
name: mac-cleaner
description: Measure disk use on macOS and safely reclaim space, find forgotten files and explain why a Mac feels slow. Use when the user asks about Mac storage, a full disk, "System Data" taking too much space, freeing up space, old screenshots, files they no longer open, "cleaning up" the computer, or making it lighter or faster. Reports first, acts only on what the user picks, and works for people with no technical background.
---

# Mac Cleaner

Find out what is using the disk, then remove only what rebuilds itself. Answer in the user's language and in plain words.

## Workflow

1. **Measure.** Run the read-only report (it can take a few minutes):

   ```bash
   bash scripts/mac-cleanup.sh analyze
   ```

2. **Recommend.** Show the free space, then a short table of what can go, its size and what the user loses. If 15% or more of the disk is free, say there is no urgency.

3. **Get a choice.** Ask which categories to clean. Never pass `--apply` until the user has picked them in this conversation; a request to "clean my Mac" is not a pick. Preview with:

   ```bash
   bash scripts/mac-cleanup.sh clean <category>...
   ```

4. **Clean.** Ask the user to close their browsers first, then run:

   ```bash
   bash scripts/mac-cleanup.sh clean --apply <category>...
   ```

   If your own rules stop you from deleting files, give the user the command to run instead.

5. **Check.** Run `df -h /System/Volumes/Data` and report the real free space.

## Categories `clean` can touch

| Category | What it removes | Cost |
|---|---|---|
| `user-caches` | `~/Library/Caches`, except macOS's own and test browsers | Apps open slower once |
| `installers` | `.dmg` and `.pkg` at the top of `~/Downloads`, moved to the Trash | None if the apps are installed |
| `uv`, `npm` | Package caches, through each tool's own command | Packages download again |
| `gradle` | `~/.gradle/caches` | Next build is slower |
| `xcode-derived-data` | Xcode build output | Next build is slower |
| `simulators-unavailable` | Simulators no installed Xcode can run | None |
| `old-logs` | Files in `~/Library/Logs` older than 7 days | None |

## Forgotten personal files

Unlike caches, these do not come back, so they only ever move to the Trash, where the user can restore them.

```bash
bash scripts/mac-cleanup.sh forgotten --all
```

| Category | What it moves to the Trash |
|---|---|
| `old-screenshots` | Screenshots on the Desktop, in Downloads or in the screenshot folder, 90+ days old |
| `old-recordings` | Screen recordings in those places, 90+ days old |
| `duplicate-downloads` | Files like `report (1).pdf` with the same bytes as `report.pdf` |
| `unopened-web-files` | Files saved from stock sites and web pages (Pngtree, Vecteezy, Adobe Stock and similar) on the Desktop or in Downloads, not opened for 6 months |

The report also lists items these categories never touch: every other loose file not opened for 6 months, folders in Downloads, everything at the top of Documents, files over 500 MB, zips beside a folder of the same name, and unused apps. For those, the user picks exact paths:

```bash
bash scripts/mac-cleanup.sh trash "<full path>" "<full path>"
```

Rules:

- Show the file list before `--apply`. Point out anything that looks like paperwork, client work or the only copy of something, and say how much space the category really frees; it is often small.
- "Not opened" comes from Spotlight. When Spotlight has no date, the script falls back to the last modified date, so the list can be wrong: this is why the user reviews it.
- Never treat a blanket request like "delete everything older than 6 months" as a choice of files. Age does not make a file worthless: passports, payslips, contracts, bank statements and medical papers sit unopened for years and still matter. Read the "Other loose files" list, warn about those by name, and suggest only files the user can clearly do without.
- After the move, remind the user that the space returns only when they empty the Trash in Finder.

## When the Mac feels slow

```bash
bash scripts/mac-cleanup.sh speed
```

Be honest about what helps. Freeing disk speeds up a Mac only when the disk is nearly full (under about 10% free). Otherwise the cause is usually memory: name the heaviest apps, the swap in use and the startup programs the user can switch off. The report changes nothing.

## Leave to the user

The script lists these under "Review first" and never removes them. Tell the user where to remove each one, in the app that owns it:

- Android emulators, iOS simulators, Steam games, Docker data, virtual machines: they hold data or take long to get back.
- iPhone backups: may be the only copy.
- AI models (Hugging Face, Ollama, LM Studio): check that the tool that uses them is still installed. An uninstalled tool's models are a good thing to remove; an installed tool's models would have to download again.
- The Trash: the user empties it in Finder. Moving a file to the Trash frees nothing until then.
- Time Machine local snapshots: macOS deletes them on its own when space runs low.

Never touch `/System`, `/Library/Extensions`, `/private/var/db`, or anything that needs `sudo`.

## Reading the results

- **`Operation not permitted`** on `com.apple.*` folders: macOS protects them. The script skips them; if a manual `rm` hits this, it is harmless.
- **`Directory not empty`** during a clean: an open app kept writing. Harmless; the rest was removed.
- **`zsh: no matches found`** on a `*.dmg` pattern: there are no such files left.
- **Free space rose more or less than expected:** macOS frees swap and purgeable space on its own, and other programs may have changed the disk. Do not credit the whole change to the cleanup, and do not guess a cause without checking.
- **"Coverage" shows a large gap:** the report could not see that space. Say so rather than presenting the report as complete. With Full Disk Access off, the Trash, Mail and app containers read as small or empty.
- **Sizes from an earlier report are stale.** Measure again before basing advice on them.
