# MacTree

Free, native macOS disk-space analyzer inspired by WizTree's fast workflow and visual disk map.

## v0.1

- Native Swift + SwiftUI macOS app
- Pick a readable disk or folder
- Async live filesystem scanning
- Logical vs allocated size
- File counts and permission-denied count
- Searchable/sortable table
- First visual storage-map prototype

## Run

1. Clone this repository.
2. Open `Package.swift` in Xcode.
3. Select the `MacTree` scheme and `My Mac`.
4. Press Run.
5. Choose a folder (start with your home folder) and press **Scan**.

Target: macOS 15+.

## Next

- Real squarified treemap
- Expandable folder hierarchy
- Finder / Quick Look / Move to Trash actions
- Full Disk Access guidance
- POSIX scanner benchmark and optimization
- Multi-million-file memory optimization
