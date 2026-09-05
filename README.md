# MacTree

Native macOS 15+ disk-space analyzer with an expandable folder tree, file-type
breakdown, search, and a treemap. Both Apple Silicon and Intel are supported.

## Download a test build

Open **Actions → macOS build → a successful run → MacTree-macOS** while signed
into GitHub. Unzip the artifact, open `MacTree.dmg`, and drag MacTree to
**Applications**. Launch that installed copy consistently.

These builds are ad-hoc signed, **not notarized**. macOS may require approval in
Privacy & Security before opening a downloaded build. Do not disable Gatekeeper.
A Developer ID and Apple notarization are needed for normal public distribution.
Ad-hoc builds may need renewed privacy approval after an update; a stable path
and bundle identifier alone do not guarantee grants survive a changed signature.

## Access without repeated probing

MacTree does not open Mail, Messages, Safari, or the TCC database to guess whether
you granted Full Disk Access. It only attempts to enumerate the selected scan.
Access errors are reported as incomplete coverage, and an unreadable root produces
an error rather than a misleading empty scan. There is no automatic settings
redirect, re-prompt, permission reset, or scan restart.

For whole-disk analysis, first add **/Applications/MacTree.app** in **System
Settings → Privacy & Security → Full Disk Access**, then quit and reopen MacTree.
Choose Whole Disk and Scan. macOS can still protect some locations even with this
grant. Without it, scanning protected folders can produce macOS consent dialogs;
MacTree cannot suppress or bypass the operating system's access controls.

You can instead use **Choose Folder** to select a smaller scope. Expand folders
such as `~/Library/Application Support/Steam/steamapps/common` to inspect games.
Unreadable contents are excluded from sizes and counted in the warning banner.
APFS snapshots, clones, hard links and purgeable space mean mapped file totals are
not an exact reconciliation of physical disk usage.

## Develop

Open **MacTree.xcodeproj** in Xcode and select MacTree / My Mac. The Swift package
uses the same six active source files; historical V4–V9 files remain in Git but
are excluded. Run `bash scripts/package.sh` on macOS to build the universal DMG.
For Developer ID signing, set `MACTREE_SIGN_IDENTITY` to an installed identity;
notarization is a separate release step.

## Manual acceptance checks on a Mac

- Launch, quit, and reopen without scanning: no protected-folder probes/dialogs.
- Scan a chosen readable folder; compare known file sizes and expand its tree.
- Scan an unreadable root: an error, not a successful zero-byte scan.
- Scan with inaccessible descendants: readable data remains, warning count > 0.
- Stop and immediately restart: old progress/completion must not replace new data.
- Grant Full Disk Access to the installed app, reopen, scan twice and relaunch:
  verify the installed build does not repeatedly request the same grants.

The build workflow verifies compilation and packaging. The privacy checks above
need an interactive Mac; CI cannot validate the user's TCC permission state.
