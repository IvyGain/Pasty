/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Pasty Database Path - Path to clips.sqlite. Defaults to ~/Library/Application Support/Pasty/clips.sqlite */
  "dbPath"?: string,
  /** Close after pasting - When checked, Raycast closes itself right after Enter pastes the selected clip. Uncheck for always-on continuous-paste mode. */
  "closeOnPaste": boolean,
  /** Page Size - How many clips to fetch per query. */
  "pageSize": "50" | "100" | "200" | "500"
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `search-clips` command */
  export type SearchClips = ExtensionPreferences & {}
  /** Preferences accessible in the `paste-snippet` command */
  export type PasteSnippet = ExtensionPreferences & {}
  /** Preferences accessible in the `paste-by-folder` command */
  export type PasteByFolder = ExtensionPreferences & {}
  /** Preferences accessible in the `recent-images` command */
  export type RecentImages = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `search-clips` command */
  export type SearchClips = {}
  /** Arguments passed to the `paste-snippet` command */
  export type PasteSnippet = {}
  /** Arguments passed to the `paste-by-folder` command */
  export type PasteByFolder = {}
  /** Arguments passed to the `recent-images` command */
  export type RecentImages = {}
}

