# MacTree for Windows — first preview

Native C# / WPF Windows port. This first milestone provides folder/drive scanning,
a virtualized folder tree and file list, a size-based disk map, drill-down,
progress, cancellation, and incomplete-scan reporting.

## Download

GitHub Actions → **Windows preview** → a successful run → **MacTree-Windows-x64**.
Extract the ZIP and launch `MacTree.Windows.exe`. Keep the extracted files together.
The package includes .NET; no SDK or separate runtime installation is needed.
Target: Windows 10/11 x64 compatible with .NET 10. This is an unsigned preview.

Start with a small known folder. Enter `C:\` to scan a drive. Double-click folders
in the file list or disk map to explore; use **Up** to return. No automatic admin
prompt is requested. Inaccessible files are skipped and marked as partial results.

## Current limits

- Uses normal directory enumeration, **not MFT scanning**. No WizTree-speed claim.
- Sizes are logical bytes, not physical allocation. Hard-linked paths are counted
  separately; junctions, symbolic links and other reparse points are excluded.
- The entire scanned model is held in memory. Very large volumes need further profiling.
- Windows UI is an initial port, not yet a complete reproduction of the Mac version.
- Search, extension summary, allocated sizes, Turkish UI and fast NTFS scanning
  are follow-up milestones. This preview has no delete operations.

## Next: NTFS backend

Implement a separate `IScanner` backend for read-only NTFS metadata enumeration,
with explicit elevation for that operation and standard enumeration as fallback.
Validate hard links, sparse/compressed files, reparse points, and changing volumes
before measuring against WizTree on the same disk. Keep normal UI non-elevated.

## Build and checks

`dotnet publish windows/MacTree.Windows -c Release -r win-x64 --self-contained true -o dist/windows`

`MacTree.Windows.exe --self-test` checks known nested totals, ordering, empty
folders, cancellation, missing roots, and a junction cycle. CI also launches and
closes a real WPF window. Manual UI/performance testing on user hardware is still needed.

## Navigation and map update

The folder tree opens automatically and follows navigation from the file list,
map, and Up button. It shows folders only; files are listed on the right.
The map renders nested folder headers and file-type colors, with a legend,
hover path/size, and selection outlines. Small tails beyond 399 siblings are
grouped with their summed sizes. Very small tiles and deep folders require
drill-down. UI regression checks use a synthetic Steam/game hierarchy and
export two screenshots; these are fixtures, not benchmark results.

## Readable folder breakdown and volume capacity

The lower panel now shows one level at a time as ranked bars, with names in a
separate column so their visibility does not depend on file size. Small items
are summed into a named navigable group. Double-click a folder or group to
explore it; Up returns to its parent. Hover shows the full name/path.

Total, used and free capacity come from Windows DriveInfo (TotalSize and
TotalFreeSpace), not from scanned logical file totals. Unsupported/unavailable
volumes show an explicit unavailable state. The capacity bar always refers to
the scanned drive, even while browsing one of its folders.
