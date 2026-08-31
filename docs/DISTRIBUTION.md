# Shipping OmniTag through Homebrew

**Formula, not cask** — and that choice is what makes it free.

A cask installs a *prebuilt* `.app` downloaded from a release. Anything
downloaded gets `com.apple.quarantine`, so Gatekeeper demands a Developer ID
signature and notarisation (~£79/year) or the user sees "OmniTag is damaged and
can't be opened". Open source changes nothing about that: Gatekeeper checks
signatures, not licences.

A formula builds from source **on the user's own machine**. Nothing is
downloaded as an executable, nothing is quarantined, no signing identity is
needed, and `make app`'s ad-hoc signature is enough. Free, open source, works.

The cost: the build machine needs the Xcode toolchain (`xcode-select --install`
is not enough — SwiftUI needs full Xcode) and a first install takes a minute or
two to compile.

## Setup

1. Push this repo to `github.com/<user>/omnitag`, tag a release (`v0.1.0`).
2. Create `github.com/<user>/homebrew-tap` with `Formula/omnitag.rb`
   (template in `packaging/omnitag.rb`; replace `OWNER` and the tarball SHA-256).
3. Install:

   ```sh
   brew tap <user>/tap
   brew install omnitag          # or: brew install --HEAD omnitag
   ln -sfn "$(brew --prefix omnitag)/OmniTag.app" /Applications/OmniTag.app
   ```

`omnitag` is unclaimed in homebrew-core and homebrew-cask. homebrew-core will
not take a GUI-only app, and homebrew-cask wants a signed download, so the
personal tap is the destination, not a stepping stone.

## If it ever ships to other people

Then pay for the Developer ID, notarise (`codesign --options runtime
--timestamp`, `xcrun notarytool submit --wait`, `xcrun stapler staple`), attach
the zip to a GitHub Release, and add a cask alongside the formula. Only worth it
when someone without Xcode needs to install it.

## Sandboxing

Not sandboxed. A tag editor needs arbitrary user-chosen folders, and a
non–App Store build has no reason to pay the entitlement cost. If OmniTag ever
targets the App Store, security-scoped bookmarks become mandatory for
remembering library folders across launches — currently it does not remember
them at all.
