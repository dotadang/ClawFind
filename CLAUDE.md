# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ClawFind is a macOS desktop file search app built with SwiftUI. It indexes user-selected directories into a local SQLite database and provides fast keyword search over file names and paths with filtering and sorting.

- **Language:** Swift 5, SwiftUI
- **Platform:** macOS 26.4+ (native AppKit/SwiftUI app)
- **Bundle ID:** `com.adang.ClawFind`
- **UI Language:** Chinese (Simplified) — all user-facing strings are in Chinese

## Build & Run

Open `ClawFind.xcodeproj` in Xcode and build/run (Cmd+R). There are no external dependencies or package managers — the project uses only system frameworks (SwiftUI, AppKit, Combine, SQLite3).

## Architecture

The entire app logic lives in a single file: `ClawFind/ContentView.swift`. It contains:

1. **`SearchItem`** — Model struct representing an indexed file/folder entry.
2. **`SortOption`** — Enum for sort modes (name, modified date, size, path).
3. **`SearchViewModel`** — `@MainActor ObservableObject` that owns all app state:
   - Manages folder selection via `NSOpenPanel` with security-scoped bookmarks for sandbox compatibility.
   - Scans directories on a background task, feeding items into the database.
   - Debounces search queries (350ms) before querying SQLite.
   - Limits displayed results to 500 items.
4. **`DatabaseManager`** — Singleton wrapping raw SQLite3 C API calls. Two tables:
   - `indexed_folders` — tracks scanned root directories and their security-scoped bookmark data.
   - `indexed_files` — stores every file/folder with name, path, relative path, type, modified date, and size. Has indexes on name, path, relative_path, item_type, modified_at, and size_bytes.
5. **`ContentView`** — The main SwiftUI view with header, search bar, filter/sort controls, result list, and status sidebar.

Database is stored at `~/Library/Application Support/ClawFind/index.sqlite`.

## Utility Scripts

- `make_icon.swift` — Standalone script that programmatically generates app icon PNGs at all required sizes. Note: its output path is hardcoded to a previous project location and needs updating if used.
