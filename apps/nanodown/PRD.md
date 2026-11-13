# nanodown — Product Requirements Document

A faithful reimplementation of [Downbit](https://downbit.app/) (v0.2.8, 2026-11-11)
in Zig 0.17 on [nanoui](../../README.md). Native UI, no webview, one binary.

Every claim below is traceable to the source material: the landing page, the
`/pricing` page, and the `/docs` tree (`docs`, `docs/formats`, `docs/browser`,
`docs/library`, `docs/subscriptions`, `docs/settings`, `docs/shortcuts`,
`docs/pro`, `docs/cli`, `docs/sites`, `docs/limits`) plus `/download`.
Where this document goes beyond what Downbit states, it says so explicitly
under **Divergences**.

---

## 1. What Downbit is

> "Download video and audio from the web. A native app, and a command line."

One field takes links and searches. Paste, drop or copy a link and it shows
what it is — its picture, title and the qualities it comes in. Return
downloads it. A link you copied waits there when you come back. Each picture
fills in with color as it downloads, its progress drawn in the picture's own
colors. What's finished becomes a library you can filter and search.

For a page no extractor knows, open it in Downbit's browser and play the
video. The media it loads — HLS, DASH, MP4, audio — shows up beside it, ready
to download. What you sign in to there is used by every download, in the app
and the command line.

Engine: one Go binary written from scratch. No Python, no yt-dlp, no FFmpeg.
Files download in ranges over several connections and streams segment by
segment; pause, quit, and pick up where it stopped. Separate video and audio
are joined into a standard MP4 by a muxer written in Go, tagged with the
title, artist, date, link and artwork that Music, TV and QuickTime show. Live
streams record until you stop them.

---

## 2. Goals and non-goals

### Goals

1. **One field, one keystroke.** A link goes in, a preview appears, Return
   downloads. No modal wizard, no second window.
2. **The download is visible.** Progress is drawn in the thumbnail's own
   colors, not a generic bar.
3. **Everything resumes.** Pause, quit, connection drop — the file picks up
   where it stopped, byte for byte.
4. **The library is the archive.** Filter, search, reopen, reveal, re-download.
5. **The CLI is the same program.** Same settings, same sign-ins, same
   library, `--json` on every command.
6. **Native.** Drawn by nanoui on the GPU. No webview, no Electron, no
   bundled runtime.

### Non-goals (stated by Downbit itself)

- **DRM.** "Media protected by DRM — as on Netflix, Disney+ or Spotify —
  can't be downloaded, by design."
- **Live streams sent as DASH.** Recorded streams are recorded; DASH live is
  not.
- **Being a general browser.** The browser exists to surface media, not to
  browse.

---

## 3. Personas

| Persona | Wants | Cares about |
|---|---|---|
| **The archivist** | A channel's back catalogue, and its new videos as they land | Subscriptions, naming templates, media-server folders |
| **The clip hunter** | One 40-second segment from a two-hour stream | Trim, keyframe-accurate cut, no re-encode |
| **The script writer** | `downbit get --json` in a pipeline | Exit codes, one event per line, `--quiet` |
| **The agent** | MCP tools to fetch media on its own | `get_media_info`, `download`, bounded to 50 items |
| **The casual user** | Paste, Return, done | Free tier, zero configuration |

---

## 4. The window

Measured against the landing page's product shot and the docs' descriptions.

```
┌──────────────────────────────────────────────────────────────┐
│  ● ● ●   ⌕  Paste a link to download, or search      ⌘L  ? ⋯ │  ← top bar
├──────────────────────────────────────────────────────────────┤
│  Library   [All]  Videos 1  Audio        ▣ Downloads         │  ← tabs
│                                                              │
│  Downloading  1 · 6s left                                    │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ ┌──────────┐  Big Buck Bunny 60fps 4K - Official …     │  │
│  │ │ ▓▓▓▓░░░░ │  YouTube · Blender · 2160p60             │  │
│  │ │  10:34   │  67%  1.1 GB / 1.6 GB · 6s left   ⏸  ✕    │  │
│  │ └──────────┘  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░      │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ ┌──────────┐  Sintel                                     │  │
│  │ │          │  YouTube · Blender · 1080p                 │  │
│  │ └──────────┘  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  │  │
│  └────────────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────────────┤
│  ▣ ~/Downloads · 412 GB free                                 │  ← footer
└──────────────────────────────────────────────────────────────┘
```

### 4.1 Top bar

- Traffic lights (macOS, `title_bar = .hidden`, lights at x=26).
- **The field.** Placeholder "Paste a link to download, or search".
  - A link: previews it. Anything that isn't a link: searches the library.
  - Pasting, dropping anywhere on the window, or returning to the app with a
    link on the clipboard fills it, marked **From your clipboard**.
  - `⌘L` focuses it. `⌘⇧V` downloads the clipboard without previewing.
- `?` opens help; `⋯` opens the overflow menu.

### 4.2 Preview (under the field, when a link is in it)

- Picture, title, `Site · Author · Quality`.
- **Quality list**: `2160p`, `1440p`, `1080p`, `720p`, `480p`, `360p`, and
  `Audio`, each with its size. The chosen one is the best the settings allow.
- **Save as**: `MP4`, `M4A` free; `MKV`, `MOV`, `WebM`, `MP3`, `Opus`,
  `FLAC`, `WAV` need Pro.
- **Trim**: a start and an end as `1:30` to `2:45`. Cut at the keyframe just
  before the start, without re-encoding. Only the bytes the part needs are
  fetched.
- **Playlist / channel**: item count, **Download All**, and **Subscribe**.
- **Return** downloads immediately with the settings, preview or not.
- No media found: says so, offers **Open in Browser**.

### 4.3 Library

- Tabs: **All**, **Videos**, **Audio**, **Failed**, **Subscriptions**
  (`⌘1`–`⌘4`; Subscriptions has no default chord in the docs, assigned `⌘5`).
- A row: thumbnail with duration badge, title, `Site · Author · Quality`,
  progress or size, and the row's actions.
- **Downloading** rows show: fraction, `downloaded / total`, speed, ETA,
  pause/resume, cancel. A queued row says how many are ahead.
- **Finished** rows show size and date.
- Drag a row to reorder the queue; right-click → **Download Next**.
- Search by title (`⌘F`).

### 4.4 Row context menu

| Item | Does |
|---|---|
| Show in Finder | Reveal the file (`Show in Explorer` on Windows) |
| Quick Look | Preview without an app (Space, macOS) |
| Get Info | Quality, format, size, length, page, path (`⌘I`) |
| Copy Link | Copy the source page |
| Download Again | Once more, as Audio Only or as Video too |
| Remove from List | Off the list, file stays (Delete) |
| Move to Trash | Delete the file too (`⌘⌫`) |

### 4.5 Footer

The downloads folder and free space. Click opens it; right-click →
**Change Folder…**.

---

## 5. The browser

`⌘B` or File → Open Browser.

- A real page view (nanoui's webview) with an address field.
- **Media on This Page**, on the right: every stream and file the page plays,
  with its qualities. Download one, or **Download All**.
- **Download Page** in the toolbar downloads the page itself, signed in as
  the browser is.
- Sign-ins persist for every download, in the app and the CLI. Sign out
  everywhere forgets them, with history and cache.

---

## 6. Subscriptions

- Paste a channel's or playlist's link, choose **Subscribe**. New videos
  download as they come out; the back catalogue does not.
- The Subscriptions tab lists each with last-checked time and how many new
  videos it found.
- Per subscription: **Check Now**, **Show Its Downloads**, **Download Videos
  / Audio Only**, **Open Page in Browser**, **Unsubscribe**.
- Cadence: every hour while open (default), every 6 hours, every day, or only
  on request. `Downloads → Check Subscriptions Now` checks all.
- Failures retry at the next check. A cron job runs `downbit subs check`
  while the app is closed.

---

## 7. Formats

| | Formats |
|---|---|
| Video | MP4, MKV, MOV, WebM |
| Audio | M4A, MP3, Opus, FLAC, WAV |

- MP4 and M4A are what the sites serve; the rest are converted after download.
- **Quality**: the highest a download picks. Prefer H.264 and AAC by default;
  turning that off allows VP9/AV1 at higher resolution.
- **Subtitles**: languages as `en,de` or `all`. Inside the video by default,
  beside it when "Subtitles inside videos" is off.
- **Sponsors** (YouTube): keep, mark as chapters, or remove.
- **Tags**: title, artist, date, link, chapters, artwork. On macOS, Finder's
  Get Info also shows the source page.

---

## 8. Settings

Six tabs, each setting searchable by name.

### General

| Setting | Does | Pro |
|---|---|---|
| Language | English, 简体中文, or the system's | |
| Save downloads to | The folder | |
| A folder for each site | `YouTube/`, `Vimeo/` | ● |
| A folder for each playlist | Named after the playlist | ● |
| File name | From title, site, author, quality, date; `/` makes folders | ● |
| Folders for a media server | Plex, Jellyfin, Emby, Kodi: channel as show, year as season, `.nfo`, thumbnails | ● |
| Skip what's already downloaded | A link whose file is still there doesn't download twice | |
| Offer copied links | Put a copied link in the field on return | |
| Keep the computer awake | Until downloads finish | |
| Show in the menu bar | Keep running with the window closed | |
| Check for new videos | Subscription cadence | |
| Notify me | When a download finishes while you're elsewhere | |
| Add to Music or TV | Audio to Music, video to TV (macOS) | ● |
| Remove from the list | Finished downloads leave the list; files stay | |
| Updates | Check, download, install on their own | |

### Formats

Download as (video/audio) · Quality · Prefer H.264 and AAC · Format ·
Title, artist and artwork · Save the thumbnail · Date files when published ·
Sponsors in YouTube videos · Subtitles · Subtitles inside videos ·
Which quality (ask per link) · Which items of a playlist (ask) · Conversion
(which FFmpeg, download it now).

### Network

| Setting | Does | Free | Pro |
|---|---|---|---|
| Downloads at once | Concurrent downloads | 2 | 8 |
| Connections per download | Parallel ranges | 4 | 16 |
| Speed limit | All downloads together, as `2M` or `500K` | | |
| Proxy | Otherwise the system's | | |

### Browser

Use the browser's sign-ins · Sign out everywhere · Bookmarklets.

### Command Line

Install the `downbit` command · AI agents (MCP) settings to copy.

### License

Start Free Trial (14 days, no key) · Activate a key · Computers (3) ·
Deactivate · Email My Key.

### Where things are kept

| System | Folder |
|---|---|
| macOS | `~/Library/Application Support/Downbit` |
| Windows | `%AppData%\Downbit` |
| Linux | `~/.config/Downbit` |

---

## 9. The command line

The app's binary is the command: with arguments it runs a command, without it
opens the app. It uses the app's settings and sign-ins, and what it downloads
shows in the app's library.

### Commands

| Command | Does |
|---|---|
| `downbit get <url>…` | Download; `downbit <url>` does the same |
| `downbit info <url>` | Title, formats, playlist items |
| `downbit formats <url>` | The formats a link offers, to choose with `-f` |
| `downbit list` | Downloads of the app and the command line |
| `downbit subs` | Subscriptions: add, remove, check |
| `downbit settings` | Show or change the app's settings |
| `downbit sites` | Sites with extractors of their own |
| `downbit ffmpeg` | The FFmpeg that converts: install, remove |
| `downbit open [url…]` | Hand links to the app's queue |
| `downbit browse [url]` | Open the app's browser on a page |
| `downbit mcp` | Serve AI agents over MCP |
| `downbit license` | `trial`, `activate <key>`, `deactivate` |

### `get` flags

| Flag | Does |
|---|---|
| `-o, --output DIR` | Folder to save into |
| `-a, --audio` | Keep the audio alone (M4A) |
| `-q, --quality Q` | `best`, `2160`, `1440`, `1080`, `720`, `480`, `360` |
| `-f, --format IDS` | Formats by ID from `downbit formats`, as `137+140` |
| `--to FORMAT` | `mkv`, `mov`, `webm`, `mp3`, `opus`, `flac`, `wav` |
| `-i, --input FILE` | Links in FILE, one a line; `-` reads stdin |
| `--items 1,3,5-7` | Choose playlist items |
| `--section 1:00-2:30` | Only that part; `1:00-` to the end |
| `--subs`, `--sub-langs en,de` | Download subtitles |
| `--sponsors-remove default` | Cut SponsorBlock's parts; `--sponsors-mark` makes them chapters |
| `--name TEMPLATE` | `{title} {site} {author} {quality} {date} {id}` |
| `--cookies FILE` | A Netscape cookie file instead of the app's sign-ins; `--no-cookies` for none |
| `--rate 2M` | Speed limit |
| `--proxy URL` | As `socks5://127.0.0.1:1080` |
| `--force` | Download though the file is there already |
| `--media-server` | Lay it out for Plex, Jellyfin, Emby, Kodi |

A live stream records until `Ctrl-C`, which saves the file; a second `Ctrl-C`
discards it.

### `--json` events

One JSON object per line: `start`, `info`, `progress`, `process`, `done`,
`error` or `stopped`.

```json
{"event":"start","url":"https://…"}
{"event":"info","title":"…","site":"Vimeo","quality":"1080p","ext":"mp4","path":"/Users/…/Title.mp4"}
{"event":"progress","fraction":0.42,"downloaded":44040192,"total":104857600,"speed":6291456,"eta":9}
{"event":"process","stage":"Merging"}
{"event":"done","path":"/Users/…/Title.mp4","size":104857600,"seconds":17.2}
```

`--quiet` prints only the paths of the files, one a line. A skipped download
says `"skipped": true` in its `done` event, with the file's path.

### Exit codes

| Code | Means |
|---|---|
| 0 | Done |
| 1 | A download failed |
| 2 | Bad usage |
| 130 | Stopped with `Ctrl-C`: run it again to resume |

---

## 10. MCP

`downbit mcp` serves agents over the Model Context Protocol on stdio.

```json
{"mcpServers": {"downbit": {"command": "downbit", "args": ["mcp"]}}}
```

| Tool | Does |
|---|---|
| `get_media_info` | What a link is, without downloading it |
| `download` | Download a link, or a playlist's items, 50 at most in a call (Pro) |
| `get_subtitles` | The text of the subtitles a video has on its site (Pro) |
| `list_downloads` | Downloads of the app and the command line |
| `list_subscriptions` | The channels and playlists followed |
| `subscribe`, `unsubscribe` | Follow or stop (Pro to follow) |

Files go in the settings' folder, whatever an agent asks. Nothing reads a
file back, addresses on the computer or its network aren't fetched, and live
streams don't record. Downloads use the browser's sign-ins.

---

## 11. Sites

Read by the app itself:

| Site | What |
|---|---|
| YouTube | Videos, Shorts, playlists, channels |
| Bilibili | Videos, bangumi, collections, series, favorites, uploads |
| Vimeo | Videos and showcases |
| Twitch | Live channels, clips, VODs |
| Kick | Live channels, broadcasts, clips |
| PeerTube | Any instance |
| Instagram, Facebook, X, Threads, Bluesky, TikTok, Reddit, Tumblr, Pinterest, Imgur | Posts |
| Dailymotion, Rumble, Odysee, VK, Douyin, Xiaohongshu, Weibo, Kuaishou, Loom, TED, Internet Archive, Streamable | Videos |
| SoundCloud | Tracks, sets, artists |
| Mixcloud, Bandcamp | Tracks and sets |

Every other page that shows its video plainly downloads from its link; for
the rest, open it in the browser and play it.

---

## 12. Shortcuts

On Windows and Linux, `Ctrl` stands in for `⌘` and `Alt` for `⌥`.

| Keys | Does |
|---|---|
| `⌘N` | Go to the field |
| `⌘⇧V` | Download the copied link |
| `Return` | Download the link in the field |
| `⌘B` | Open the browser |
| `⌘F` | Search downloads |
| `⌘1`–`⌘4` | All, Videos, Audio, Failed |
| `⌘⌥P` / `⌘⌥R` | Pause all, resume all |
| `⌘⇧K` | Clear finished from the list |
| `⌘⇧O` | Show the downloads folder |
| `Space` | Quick Look the selection (macOS) |
| `⌘I` | Get Info |
| `Delete` | Remove from the list |
| `⌘⌫` | Move to Trash |
| `⌘,` | Settings |

Menu bar icon: downloads the copied link, opens the browser, pauses or resumes
everything. Dock/taskbar icon shows running count and progress.

---

## 13. Pricing (as published)

| | Free | Pro |
|---|---|---|
| Price | $0 forever | $19 once ($9.50 until 2026-11-14) |
| Computers | — | 3 |
| Sites, any page | ● | ● |
| MP4 / M4A | ● | ● |
| MKV, MOV, WebM, MP3, Opus, FLAC, WAV | | ● |
| Photo posts, whole | ● | ● |
| Browser | ● | ● |
| Library, filter, search | ● | ● |
| Pause, quit, resume | ● | ● |
| Skip what's downloaded | ● | ● |
| Downloads at once / connections | 2 / 4 | 8 / 16 |
| Trim a part | | ● |
| Skip sponsors | | ● |
| Subscriptions | | ● |
| Record live streams | | ● |
| Naming, folders, media-server layout | | ● |
| Add to Music / TV | | ● |
| Command line | | ● |
| MCP for agents | | ● |
| Updates | ● | ● |

14-day trial of all of Pro, no key, one per computer. License checked offline,
renewed with the server about monthly, works 30 days without a connection.

---

## 14. Architecture (nanoui)

```
apps/nanodown/
  build.zig            one binary: `nanodown`, and `nanodown --cli` for the command line
  build.zig.zon        nanoui by path
  PRD.md               this document
  src/
    main.zig           entry: GUI or CLI by argv
    app.zig            state: settings, library, queue, subscriptions, selection
    theme.zig          Downbit's palette and measures
    model/
      media.zig        Media, Format, Item: what a link is
      download.zig     a download's state machine and its bytes on disk
      library.zig      the persisted list
      settings.zig     every setting, its default, its Pro gate
      subscription.zig channels and playlists followed
      license.zig      trial, key, computers
    engine/
      extract.zig      link → Media (site dispatch)
      sites/           youtube.zig, bilibili.zig, vimeo.zig, twitch.zig, generic.zig …
      http.zig         ranged GETs over nanoui.http, resume, speed limit
      hls.zig          playlists, segments, live
      dash.zig         manifests, representations
      mux.zig          MP4 boxes: join video+audio, tags, chapters, artwork
      convert.zig      FFmpeg discovery and invocation
      naming.zig       templates, site/playlist folders, media-server layout
      sponsors.zig     SponsorBlock
      subs.zig         subscription checking
    cli/
      main.zig         argv parsing, exit codes
      json.zig         the event stream
      mcp.zig          MCP over stdio
    ui/
      view.zig         the window
      topbar.zig       field, preview trigger, overflow
      preview.zig      the link's card
      library.zig      tabs, rows, queue
      row.zig          one download
      browser.zig      the page view and Media on This Page
      settings.zig     six tabs
      info.zig         Get Info
      footer.zig       folder and free space
      menu.zig         the menu bar
    tests/             Tester-driven, offscreen
```

### Why this shape

- **`model/` is pure.** No IO, no UI. Every rule that can be tested without a
  window lives here, and `zig build test` runs it everywhere.
- **`engine/` owns the network and the disk.** `nanoui.http.send` is
  synchronous and thread-safe, so ranged downloads run on worker threads and
  report back through `App.after` / `Context.requestFrameFromAnyThread`.
- **`ui/` draws only.** A view reads `*App` and writes nothing but selection
  and intent.
- **`cli/` shares everything.** The command line is the same `model/` and
  `engine/`, so settings, sign-ins and the library are literally the same
  files.

### Threading

Download workers are `std.Thread`s. Each owns one `Download`, writes its own
file region, and publishes progress as an atomic fraction. The UI reads the
atomics on its frame; nothing polls — a worker that made progress calls
`requestFrameFromAnyThread` only when the drawn value would change by more
than a pixel.

### Persistence

`library.json`, `settings.json`, `subscriptions.json`, `license.json` in the
app's folder, written on change through `std.Io.Dir.writeFile` and read at
start. The partial files live beside the target as `<name>.part`, with a
sidecar `<name>.part.json` recording the ranges already fetched.

---

## 15. Milestones

| # | Milestone | Done when |
|---|---|---|
| 1 | Skeleton, theme, window, library list | The window draws with sample rows, `zig build run` shows it |
| 2 | Model + settings + persistence | Settings round-trip through disk; tests pass |
| 3 | Ranged download engine | A direct MP4 URL downloads, pauses, resumes, and finishes byte-exact |
| 4 | Extractors: generic, YouTube, Vimeo, direct | `info` returns title/formats for each |
| 5 | HLS + DASH | A playlist and a manifest download and join |
| 6 | Mux, tags, naming | Two streams become one tagged MP4; templates and folders apply |
| 7 | The preview and the queue | Return downloads from the field; rows show live progress |
| 8 | Library actions | Reveal, trash, re-download, Get Info, search, filter |
| 9 | CLI + `--json` + exit codes | The documented commands and events all work |
| 10 | Subscriptions | A channel is followed and its new items download |
| 11 | Browser + Media on This Page | A page's streams are listed and downloadable |
| 12 | Settings UI, license, MCP | Six tabs, trial gate, MCP tools |

---

## 16. Divergences from Downbit

Stated plainly, because a reimplementation that pretends otherwise is a lie.

1. **No Go, no FFmpeg, no yt-dlp — by construction.** Downbit's engine is Go
   with a hand-written muxer. nanodown's is Zig, and its muxer is Zig. Where
   Downbit shells out to FFmpeg for conversion, nanodown does the same only if
   an FFmpeg is present, and otherwise offers the formats it can produce
   natively (MP4, M4A) and says so — it does not silently degrade.
2. **Extractor coverage is a subset at first.** Downbit reads ~30 sites. This
   implementation starts with the generic path (direct media, `og:` metadata,
   `<video>`/`<source>`, HLS and DASH manifests) plus YouTube, Vimeo, Twitch,
   Bilibili and SoundCloud. The rest report "no media found" and offer the
   browser, which is Downbit's own fallback.
3. **Sign-in reuse is the webview's cookie jar**, not a bespoke credential
   store. On macOS that is WKWebView's data store; on Windows, WebView2's
   profile folder. This is the same mechanism, named honestly.
4. **The license server is not implemented.** The trial, the key format, the
   three-computer rule and the offline check exist locally; there is no
   server to verify against, so a key is validated by its own signature and
   the app never phones home. Downbit renews monthly; nanodown does not.
5. **No update channel.** Downbit updates itself from GitHub releases.
   nanodown has no release to update from.
6. **SponsorBlock and Quick Look** are macOS-only in the reference and are
   implemented here only where the platform offers the hook.
7. **The iOS and Android builds** are not attempted. Downbit ships macOS,
   Windows and Linux.

---

## 17. Acceptance

A build is acceptable when, without a window:

```sh
zig build test                                  # model, engine, UI tests offscreen
zig-out/bin/nanodown --nanoui-snapshot=/tmp/down.png --nanoui-script="click:All"
zig-out/bin/nanodown info https://vimeo.com/76979871 --json
zig-out/bin/nanodown get -q 720 -o /tmp/out https://vimeo.com/76979871 --json
```

all succeed, and the snapshot shows the library with its rows, tabs and
footer drawn as section 4 describes.
