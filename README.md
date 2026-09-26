# DuckDuckGo with extensions (unofficial)

A patched build of [DuckDuckGo for Mac](https://github.com/duckduckgo/apple-browsers) that lets you install Chrome/WebExtensions, and that runs alongside the regular DuckDuckGo app without touching its data.

DuckDuckGo already ships WebKit's extension engine inside the browser, but it's switched off behind a remote flag and has no UI for installing your own extensions. This fork turns it on and adds the missing pieces.

> Not affiliated with or endorsed by Duck Duck Go, Inc. Use at your own risk.

## Why this exists

DuckDuckGo's Mac browser has been out since 2022, and extension support has been one of the most requested features the whole time. Four years on, it still isn't there, even though the engine is already built into the app and just switched off.

So this fork switches it on. **The day DuckDuckGo ships extension support in the official app, I'll archive this repo.** Until then, here you go.

## What's different from stock DuckDuckGo

**Extensions**
- **File → Install Extension…** takes a `.crx`, a `.zip`, or an unpacked extension folder.
- **File → Install Extension from Link…** takes a Chrome Web Store URL.
- Each extension gets a toolbar button that opens its popup. Right-click the button for options, hiding it, or removing the extension.
- **Settings → Extensions** lets you enable, disable, configure and remove extensions.

**Runs next to the real DuckDuckGo**
- Separate bundle ID (`io.github.axxzywastaken.ddgext`), sandbox container, and keychain items. Your bookmarks, passwords and settings in stock DuckDuckGo are never read or changed.

**No phoning home**
- Usage pixels, wide events, ATB install statistics and crash report uploads are all off.
- The Sparkle updater is off. Otherwise it would "update" this app into stock DuckDuckGo.

## Requirements

- Apple Silicon Mac for the release build. Intel Macs can build from source: `build.sh` targets the machine it runs on.
- **macOS 15.4 or later** for extensions. The browser itself still runs on 12.3+, just without extensions.

## Install a release build

1. Download the zip from [Releases](../../releases) and unzip it.
2. Move **DDG Extensions Dev.app** to Applications.
3. The app is ad-hoc signed, not notarized, so macOS will block the first launch. Either right-click → Open, or run:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/DDG Extensions Dev.app"
   ```

## Build it yourself

Needs an Xcode with the macOS 15.4 SDK or newer (built and tested with Xcode 27.0).

```sh
git clone https://github.com/AxxzyWasTaken/duckduckgo-extension-support
cd duckduckgo-extension-support
fork/build.sh
```

The app lands in `build/out/`. The first build takes several minutes. `fork/package.sh` repackages and re-signs without recompiling.

### Moving to a newer DuckDuckGo release

The fork's changes are ordinary commits on top of an upstream release tag (tags look like `1.209.0-816+macos`), so updating is a rebase:

```sh
git remote add upstream https://github.com/duckduckgo/apple-browsers
git fetch upstream tag <new tag> --no-tags
git rebase --onto <new tag> 1.209.0-816+macos main
```

## Where the changes are

| Path | What it is |
|---|---|
| `macOS/DuckDuckGo/WebExtensions/Fork/` | Installer, toolbar buttons, Settings pane |
| `fork/Fork.xcconfig` | Bundle IDs, app groups and updater settings, copied into upstream's `LocalOverrides.xcconfig` hook at build time |
| `fork/build.sh`, `fork/package.sh` | Build, then package and ad-hoc sign |
| [Compare with upstream](https://github.com/duckduckgo/apple-browsers/compare/1.209.0-816%2Bmacos...AxxzyWasTaken:duckduckgo-extension-support:main) | Every change, including the small hooks in upstream files |

Upstream's own README is in [UPSTREAM-README.md](UPSTREAM-README.md). This fork only builds the macOS app; the iOS code is untouched.

## Known limitations

- **No auto-updates.** New DuckDuckGo versions need a rebuild (see above).
- **No DuckDuckGo subscription features** (VPN, Personal Information Removal, Duck.ai paid tier). They need DuckDuckGo's own code-signing team and are removed from the build.
- **No Sync or Passwords shared with stock DuckDuckGo.** That's deliberate: the two apps are kept fully separate.
- **Extension coverage is whatever WebKit supports.** Manifest V3 extensions work best. Chrome-only APIs that Safari's engine lacks won't work. Tested so far: uBlock Origin Lite.

## License

Apache License 2.0, same as upstream. See [LICENSE.md](LICENSE.md) and [NOTICE](NOTICE).
