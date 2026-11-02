# Dandelion

**Make a wish. Clear your Mac.** A free, open-source toolkit that fixes the everyday mess on your Mac.

**[Download Dandelion.dmg](https://github.com/cwxyz-tech/dandelion/releases/latest/download/Dandelion.dmg)** · [Project page](https://coleswebsite.xyz/dandelion/) · macOS 14 or later · Apple silicon and Intel

See what's eating your disk, clear out duplicate files, and keep folders tidy on their own. Each tool replaces a paid Mac utility, and nothing ever leaves your Mac.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img src="docs/screenshot-light.png" alt="Dandelion's Disk Map: a sunburst chart of a folder, with its biggest items listed alongside">
</picture>

| Tool | What it does | Like | Status |
| --- | --- | --- | --- |
| **Disk Map** | Your disk as an interactive sunburst, so the big forgotten folders jump out | DaisyDisk | Ready |
| **Duplicates** | Finds identical files and keeps just one of each | Gemini | Ready |
| **Folder Rules** | "Trash old installers", "sort Downloads by type": folders that tidy themselves | Hazel | Ready |
| **Screenshot** | Capture, mark up, blur and pin screenshots | CleanShot X | Planned |
| **Time Tracker** | See which apps your day goes to, kept on your Mac | Timing | Planned |
| **Screen Recorder** | Recordings that zoom smoothly to your clicks | Screen Studio | Planned |

<img src="icon-1024.png" alt="Dandelion icon" width="160">

## Disk Map

- **Fast scanning.** Reads each folder in batches with `getattrlistbulk` (one system call per batch of entries, instead of one `stat` per file), spread across every CPU core.
- **Interactive sunburst.** Click a folder to dive in, click the middle to go back up, hover anything to see its size.
- **Sorted list** of the current folder alongside the chart, with breadcrumbs back up the path.
- **Collector.** Drag files and folders to the bar at the bottom (or press Delete), then move them all to the Trash at once. Nothing is ever deleted outright; it all goes to the Trash.
- **Safety checks.** Right before anything moves, Dandelion makes sure it's still the same file in the same folder it scanned, and it refuses to touch folders macOS needs.
- **Smooth.** The map sweeps in, rings bloom as you dive into folders, slices lift on hover, lists glide in. Reduce Motion turns it off.
- **Quick Look** (Space), Reveal in Finder, Open, Copy Path from the right-click menu.
- **Hidden space.** The part of the disk the scan can't see (the sealed system volume, snapshots, purgeable caches, unreadable folders) shows up as a grey slice, so the chart adds up to what the disk says is used.
- **Accurate sizes.** Counts the space actually allocated on disk, and counts hard-linked files once.
- Native SwiftUI, Apple Silicon and Intel, light and dark mode. No network access, no analytics, no accounts.

## Build it

You only need Apple's free Command Line Tools (not the full Xcode):

```sh
xcode-select --install     # once
./build.sh                 # makes build/Dandelion.app
```

`ARCHS=arm64 ./build.sh` builds for Apple Silicon only, which is faster.

`./make-dmg.sh` then packs it into `build/Dandelion.dmg`, the usual "drag the app onto Applications" disk image.

Then drag `build/Dandelion.app` into Applications. An app you build yourself opens without any Gatekeeper warning.

## Downloading a build instead

Every push is built on a Mac by GitHub Actions (`.github/workflows/build.yml`). Putting a new number in `VERSION` (like `1.1`) publishes a release with `Dandelion.dmg` and `Dandelion.zip`, with their SHA-256 checksums in the notes.

Open the .dmg and drag Dandelion onto Applications. Downloaded builds are ad-hoc signed, not notarized, so the first launch gets blocked. To open it: try to open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or in Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Dandelion.app
```

## Duplicates

- Compares sizes first, then a fingerprint of each file's first 64 KB, then the full contents with SHA-256, hashing in parallel.
- Hard links, symlinks and the insides of app bundles and photo libraries are never treated as duplicates.
- Pick which copy to keep (oldest, newest, or nearest the top); it can never select every copy of a file.
- Right before moving anything, it checks the file hasn't changed and the copy you're keeping is still there.

## Folder Rules

- Conditions: kind (image, video, installer, app, screenshot...), name, extension, how long ago it was added or changed, size. Match all or any.
- Actions: move to a folder, sort into folders by type or by month, or move to the Trash.
- Preview any rule before it runs. Run by hand, or automatically: new files are handled a few seconds after they land, plus a sweep every 15 minutes.
- With automatic rules on, closing the window keeps Dandelion running in the menu bar (no Dock icon), so your folders stay tidy. Quit from the menu bar item.
- Installers (.dmg, .pkg) and apps (.app) are separate kinds, so "clear out old installers" never trashes an app.
- Only looks at files sitting directly in the folder, skips anything still downloading, never overwrites (a clash gets "name 2"), refuses system folders, and every run can be undone.
- Rules are saved in `~/Library/Application Support/Dandelion/rules.json`, readable only by you.

## In the next update

- Folder Rules keep running from the menu bar after you close the window
- Apps are their own kind in Folder Rules, so installer rules can't catch them
- The sidebar only shows tools that are ready
- Screenshots in the README, taken from the real app on every build

## What's new in 2.0

- Dandelion is now a suite: Disk Map, Duplicates and Folder Rules in one sidebar
- New icon and a motto: make a wish, clear your Mac
- Every engine (scanner, duplicates, rules) is checked on a real Mac on every change

## What's new in 1.1

- A much faster scanner (`getattrlistbulk`, self-balancing parallel work) that uses less memory per file. Measured 2.4× faster than 1.0 on a 118,000-file folder, with identical totals (see `Tests/ScanCheck.swift`)
- Safety checks before the Trash: same file, same folder, and protected system and home folders
- Animations throughout, with Reduce Motion respected
- Faster drawing on huge folders: cached chart shapes, instant hit-testing, icons that don't touch the disk
- Disguised file names (invisible or direction-flipping characters) are shown plainly
- Hardened runtime, Delete to collect, live disk list, a Trash sound and confirmation

## Security

- No network access at all, no analytics, no accounts.
- Built with the hardened runtime.
- Folders are opened with `O_NOFOLLOW`, so a link swapped in mid-scan is never followed off the disk.
- Before moving anything to the Trash it checks the file ID and its folder's ID against the scan, and blocks system folders, your home folder's top-level folders, and other users' homes.
- Everything goes to the Trash; nothing is deleted outright.

Found a problem? Please open an issue.

## Full Disk Access

macOS hides some folders (Mail, Messages, Safari, other apps' containers) from every app unless you allow it. Dandelion shows a banner when it can't see them. To see everything: **System Settings → Privacy & Security → Full Disk Access**, turn on Dandelion, then rescan.

## How it works

| File | What's in it |
| --- | --- |
| `Sources/Scanner.swift` | The parallel disk scanner |
| `Sources/Model.swift` | The file tree, disk list and formatting |
| `Sources/AppState.swift` | Scanning, navigation, the collector, Trash |
| `Sources/Sunburst.swift` | Laying out and drawing the chart, hit testing |
| `Sources/Views.swift` | The screens |
| `Sources/Safety.swift` | Checks before anything goes to the Trash |
| `Sources/Duplicates.swift`, `Sources/DuplicatesUI.swift` | The Duplicate Finder engine and its screens |
| `Sources/Rules.swift`, `Sources/RulesUI.swift` | The Folder Rules engine, its screens and the folder watcher |
| `Sources/Suite.swift` | The sidebar of tools |
| `Sources/Icons.swift` | Fast, cached file icons |
| `Sources/App.swift` | App entry point, menus and the menu bar item |
| `Sources/ReadmeShots.swift` | Takes the README screenshots in CI (only when run with `--snapshot`) |
| `Tests/ScanCheck.swift`, `Tests/SuiteCheck.swift` | Checks for the scanner, Duplicate Finder and Folder Rules on tricky test folders (run in CI: `sh Tests/run.sh`) |
| `docs/` | The project page (GitHub Pages) |

On the startup disk, Dandelion scans the Data volume (`/System/Volumes/Data`), which is where all your files live. Other mounted disks aren't counted, even if they're mounted inside the folder being scanned.

## License

MIT. See [LICENSE](LICENSE).
