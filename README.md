# mac-cleaner

An agent skill and Bash script that show what is using the disk on a Mac, find files you forgot about and explain why it feels slow.

- **Nothing changes by default.** `clean` is a dry run until you add `--apply` and name each category.
- **Never uses `sudo`** and never empties the Trash. Installers, screenshots and forgotten files go to the Trash, so you can put them back.
- **Keeps what is expensive to lose.** Emulators, backups, games and AI models are listed for you to review, never removed.
- **Says what it could not see.** The report compares what it measured with what the disk reports.

Requires macOS and the Bash that ships with it. No dependencies.

## Use it from the terminal

```bash
bash scripts/mac-cleanup.sh analyze
```

```bash
bash scripts/mac-cleanup.sh clean
```

```bash
bash scripts/mac-cleanup.sh clean --apply user-caches installers
```

List old screenshots, exact copies and files not opened in 6 months:

```bash
bash scripts/mac-cleanup.sh forgotten
```

Move what you chose to the Trash:

```bash
bash scripts/mac-cleanup.sh clean --apply old-screenshots duplicate-downloads
```

```bash
bash scripts/mac-cleanup.sh trash "$HOME/Downloads/old-file.pdf"
```

See memory use and the programs that start on their own:

```bash
bash scripts/mac-cleanup.sh speed
```

Categories: `user-caches`, `installers`, `uv`, `npm`, `gradle`, `xcode-derived-data`, `simulators-unavailable`, `old-logs`, `old-screenshots`, `old-recordings`, `duplicate-downloads`, `unopened-files`. [SKILL.md](SKILL.md) explains what each one does.

## Use it as a skill

Clone this repository into your agent's skills folder. For Claude Code:

```bash
git clone <repository-url> ~/.claude/skills/mac-cleaner
```

Then ask something like "why is my disk full?". The agent reports first and asks before cleaning anything.

## Tests

The tests run against a throwaway home folder, with `uv`, `npm` and `xcrun` replaced by stubs:

```bash
bash tests/run-tests.sh
```

## License

[MIT](LICENSE)
