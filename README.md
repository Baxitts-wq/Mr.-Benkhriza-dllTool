# Mr. Benkhriza â€” Steam DLL Tool
**by Benkhriza**

> Retro hacker-style launcher for managing your Steam Lua configs.  
> Drag, drop, done. No command line BS.

---

## what is this

A WPF GUI for Windows that handles everything around the OpenSteamTool engine â€” injecting Lua files into Steam, keeping a local game database, syncing from GitHub, music playback while you work, and a clean terminal-style interface that doesn't look like garbage.

Built for personal use, cleaned up enough to share. It's not bloated. It does one thing well.

---

## getting started

**You need a license key to run this.** Contact me on Discord or drop an issue here.

Once you have your key:

1. Extract the folder somewhere (not inside another zip, just a normal folder)
2. Right-click `Setup.bat` â†’ **Run as Administrator**
3. When Setup finishes, find the **Mr. Benkhriza** shortcut on your Desktop
4. Paste your license key into `mr_benkhriza_gui.json` â€” the `LicenseKey` field
5. Double-click the shortcut, it'll bind your PC automatically

First launch locks the key to your hardware. If you change PC, message me and I'll reset it.

---

## features

- drag-and-drop Lua injection directly into Steam's config folder
- bundled offline database with 19+ game configs (works without internet)
- GitHub sync to pull the latest Lua files from the repo
- Steam Store search (AppID lookup, no API key needed)
- built-in music player with playlist support (mp3/wav in the Songs folder)
- matrix rain boot animation because why not
- full logging to disk

---

## file layout

```
Mr. Benkhriza.ps1     main script / WPF controller
Mr. Benkhriza.xaml    UI layout (XAML)
Setup.bat             run this first, sets up everything
Mr. Benkhriza.bat     manual launcher if shortcut breaks
mr_benkhriza_gui.json config â€” put your license key here
database/             bundled Lua game configs (offline fallback)
SteamFiles/           DLL hooks for Steam
lib/                  helper scripts (lua fetcher etc.)
Songs/                drop your music files here
```

---

## how Lua files work (quick explainer)

Steam breaks games into "depots" â€” exe, DLC packs, language files, etc. Each depot has an AES-256 key.  
When you buy a game, Steam hands your client those keys. The Lua file is just a list of `addappid()` calls with those keys:

```lua
addappid(1091500, 1, "cf941dce25dfe...")
--       ^ AppID  ^  ^ depot decryption key
```

Sites like openlua.cloud pull those keys from legit owners and build a public database.  
This tool just helps you manage and apply those configs without touching the command line.

---

## how to get Lua files

1. Find your game's AppID on the Steam store page (it's in the URL)
2. Go to openlua.cloud and search for it
3. Download the `.lua` file
4. Drag it into the drop zone in the GUI

It hot-reloads into Steam â€” no restart needed.

---

## music player

Drop `.mp3` or `.wav` files into the `Songs/` folder next to the script.  
Name them in play order if you want (`01 - somesong.mp3`, `02 - another.mp3`).  
Use the TRACK dropdown in the GUI to pick a song, click the music button to play/pause.

---

## troubleshooting

| issue | fix |
|---|---|
| "access denied" on launch | license key is wrong or not entered yet |
| Setup.bat fails | right-click â†’ run as administrator |
| Steam path not found | enter it manually when prompted during setup |
| GUI won't open | make sure the folder wasn't moved after setup â€” re-run Setup.bat |
| game shows 0 bytes download | the Lua file might not have that depot key yet |

---

## license

Personal use only. Don't redistribute without permission.  
The OpenSteamTool engine is by its original authors â€” this is just a frontend for it.

*â€” Benkhriza*
