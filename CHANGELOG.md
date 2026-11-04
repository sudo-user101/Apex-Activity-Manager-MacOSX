# Changelog

## 1.6.2 (2026-11-04)

Crash fixes, safer error messages and security fixes. No new features.

- **Stay Awake:** changing the "on battery" time no longer crashes Apex.
- **Server terminal:** output from a server can no longer stop Apex. Fixed huge
  numbers in control sequences, marks after invisible characters, leaving
  full-screen programs after the window shrinks, and copying below the last
  row. Endless control sequences are now limited.
- **Other crashes fixed:** a helper program quitting while Apex writes to it, an
  archive claiming huge sizes, a malformed answer from a server, huge sizes on
  a cloud page or in a box, negative sizes from a server, and a full disk
  while extracting (now an error message).
- **Honest results:** when a file can't be moved to the Trash after compressing
  or extracting, Apex now says so instead of reporting success.
- **Security:** settings that could send a saved AI key to another server now
  exist only in development builds.
- **Signing:** Apex is signed by CyberNet Labs. macOS still asks you to confirm
  the first time you open it.

## 1.6.1 (2026-11-04)

- **Shelf:** a picture dragged from a browser goes on the shelf at full
  size. Browsers hand over only a thumbnail (a Google Images result gives
  225 × 225), so Apex downloads the original from the site (the picture
  behind an image search result, or the one on the page); if the site
  refuses, the thumbnail goes on instead.

## 1.6.0 (2026-11-03)

- **Apps** (a server with Apex Server Edition 1.3): every WordPress site,
  in Docker or installed on the server, and Ghost, Nextcloud, Gitea,
  Grafana, MinIO, Node.js and the databases (MySQL, MariaDB, PostgreSQL,
  Redis, MongoDB), grouped by kind, sites first, each with the domains it
  serves; stopped containers marked.
- **Server Edition updates:** Manage shows the server's Apex Server
  Edition version, "Version X is available" with **Update**, and **Check
  Now**. Servers on 1.2 or earlier get the command to update them once by
  hand.
- **Startup:** apps that open at login were missing on recent macOS (the
  list Apex read now needs the administrator password). They come from
  System Events now, with who made each from its signature; **Show
  Background Items** lists the rest, after macOS asks for your password.

## 1.5.0 (2026-10-30)

- **Manage** (a server with Apex Server Edition 1.2): a control panel for
  the server, as root.
  - **Terminal:** a root shell, drawn by Apex's own terminal (colours,
    full-screen programs like htop, nano and vim, scrollback, copy and
    paste).
  - **Files:** browse anywhere, edit text files, upload and download,
    rename, delete, permissions and owner.
  - **Updates:** security updates first; install all, security only or
    selected; install or remove a package; restart when needed.
  - **Security:** firewall rules (ufw or firewalld; SSH and Apex are kept
    open), fail2ban, SSH sign-in settings, users and their SSH keys.
  - Off until it's switched on at the server: `sudo apex-server allow panel`.
- **Moving a server to another port** keeps its pairing; the message says
  which port Apex tried.
- **Sites:** Nginx Proxy Manager sites show where they forward.

## 1.4.0 (2026-10-29)

- **All Servers:** every server added up (CPU weighted by cores, memory,
  network, disk) with live graphs, and a list you can sort by any column.
  Servers that don't answer show a red dot, are greyed out and say why:
  this Mac is offline, isn't on the server's network, or the server is off.
- **Resume and Stop:** start, unpause and stop a container (on this Mac or
  on a server); shut a server down, and wake it with Wake-on-LAN where its
  network card allows. Stop always asks first.
- **Sites** (with Apex Server Edition 1.1): every nginx, Caddy, Traefik and
  Nginx Proxy Manager site on a server, where it forwards, its HTTPS
  certificate and its traffic over the last 10 minutes; add, edit, switch
  off and remove sites, each change checked by the proxy and undone if
  it's refused.
- **Docker Management:** containers grouped by stack and the manager that
  runs them (Dockge, Portainer, Compose), logs, stack up / update / down,
  compose files checked before they're saved, images, volumes and
  networks. Through Server Edition or over SSH.
- **Pairing works on any address:** cloud and public addresses were
  refused by macOS; Apex now checks the server's certificate itself, and
  keeps working when Server Edition renews it.
- **Utilities:** Window Manager (snap, shortcuts, layouts), App Switcher
  (window previews), Clean Keyboard, Preview-Folder with a full archive
  manager, Clipboard History and Drop Shelf, each with its own page.
- **Settings › MacOSX Change:** hidden macOS settings and keyboard and mouse
  behaviours in one place.
- **Storage:** Diagnose, Compress in place (photos, videos, PDFs, folders,
  cloud folders), Analyze shows what things look like.
- **Cloud Disks:** an overview of every service, Add Service in three steps,
  trash on each file, online-only files counted without downloading.
- **Menu bar:** Sound (media controls and volume per app), a new icon.
- **Energy:** battery time left from your own use; the charge limiter can
  run the Mac from the adapter at the limit.
- **Permissions:** Allow All asks one at a time and waits; switches keep
  working after updates; the Accessibility prompt no longer repeats.
- Fixes: saved passwords that another copy of Apex couldn't read, a
  security review (archive paths, command options, SSH hosts, passwords
  over http), and many smaller ones.

## 1.3.0 (2026-10-26)

- **Servers and containers:** add Linux servers (SSH, or the new
  [Apex Server Edition](https://github.com/sudo-user101/Apex-Activity-Manager-Server-Edition))
  and see Docker containers in the This Mac menu. Pick one and the whole app
  shows it: Processes, Performance, Users, Services, and a **Report** tab
  (last 1, 6 or 24 hours, what happened and what was busiest, save as PDF),
  plus a report for all servers or all containers at once.
- **Apex Server Edition pairing:** enter the server's address and the
  one-time pairing code; Apex remembers the server's certificate and refuses
  any other. End processes and start, stop or restart services and
  containers, without sudo or SSH.
- **Census** (Processes › More, ⇧⌘K): the top apps for CPU, memory, energy,
  disk, network and GPU in one view.
- **Energy:** select what's using power and End Task or Force End it.
- **Memory page:** calmer colours, a clearer graph, and a breakdown in three
  columns (overview, composition, memory pressure). Pressure is shown as
  macOS's own score, coloured by its state. Swap has a round, easy-to-hit
  button.
- **Assistant:** ask about your Mac with a local model, or any AI provider
  with your own key (named, grouped keys, checked when saved, nothing
  spent); Apex Agent can quit apps and stop processes when you ask and
  confirm.
- **Settings:** a native window with General, Alerts, History, Shelf and
  Permissions tabs.
- **Shelf:**
  - Opens as a stack.
  - Drag single files out of the list.
  - Every kind of drop lands, and a failed one says why.
  - Dropping files back on their own shelf no longer duplicates them.
  - Kept shelves in the menu bar show a pile, a count and an icon.
  - Pin up to 5, pinned first.
  - After you drop its files into an app or a folder, the floating shelf
    flies into the menu bar and waits in the menu bar's Shelf tab.
- **Safer Quit and Force Quit:** Apex now remembers exactly which process
  you chose (not just its number), and macOS itself refuses the action if
  that process has quit and its number was reused. Quit from an alert asks
  first. Ending another user's process as administrator re-checks each one.
- **Network › Shell:** ready-made commands in categories with live output.
- **Cloud Disks:** says when a service's app is signed out or not open.
- **Remove app** also finds system files, installer records and sign-ins.
- **Disk › Clean:** plain words, safety labels, and a Free Up button.

- **Signed and notarized releases:** `build.sh --notarize` signs the app and
  its helper with a Developer ID (hardened runtime, secure timestamp),
  notarizes and staples the app and the .dmg; credentials come only from
  environment variables. A release workflow does it all when a version tag
  is pushed and publishes the .dmg with its SHA-256
  ([Releasing](docs/RELEASING.md)).
- New README, a website (`site/`, published with GitHub Pages), a security
  policy explaining the helper and every password prompt, contribution
  guidelines, and bug report and feature request forms.

## 1.2.0 (2026-10-25)

- **Cloud Disks** (Performance): iCloud Drive, OneDrive, Google Drive,
  Dropbox, Nextcloud and other synced folders, plus your own folders and
  WebDAV servers. See what's on this Mac and what's online only, make files
  online-only (or offload everything), and check uploads: speed, time left,
  whether the server can be reached and why not, a ring per file (uploading,
  paused, can't upload), pause and resume. Online storage from WebDAV, the
  provider's own page, or typed in.
- **Display** page: brightness for built-in and external monitors,
  resolutions, arrangement and AirPlay devices.
- **Network:** one page per connection (Wi-Fi, Ethernet, VPN), public IP
  (hide it with the eye), internet speed test, **Network Doctor**, a clear
  Pause for the traffic list, and double-click an app for its last
  10 minutes and every server it talked to.
- **Menu bar:** Monitor, Energy, Shelf, Clipboard and Sessions tabs; click
  three times to open Apex.
- **Shelf:** a floating shelf appears when you drag a file (wiggle it for a
  new one). Files sit as a stack (drag them all out at once) or a list;
  minimize to the side, the menu bar or a category. Compress photos, videos,
  PDFs and anything else (ZIP), compare with the original side by side,
  remove photo and video details without losing quality.
- **Record:** save everything Apex measures to a file you can hand to an AI
  to find out what was going on; or record just one resource from its page.
- **Energy:** power mode, Stay Awake (for a while, on chosen days, or with
  the lid closed for chosen apps), power in detail, accessories with power
  estimates; the graphs come first.
- **Memory:** optimized apps are remembered, and Restore All is always there.
- **Assistant** (Local AI): ask a model on your Mac about your Mac, with
  Apex's live readings.
- **Remove apps** with or without everything they left behind.
- **First launch:** a welcome tour and every permission in one place.
- Bootable Media Creator: drivers folder, computer name, time zone, and no
  automatic device encryption.
- Fixes: a memory leak in Clean, charge schedules stopping when Apex quit,
  smoother animations, and nothing heavy on the main thread.

## 1.1.0 (2026-10-24)

- Faster storage scans: Clean, Analyze and drive Storage measure folders in
  parallel across all CPU cores (about 2× faster on caches in testing).

- Accessories: stop a USB drive and resume it without unplugging it, and
  disconnect / reconnect Bluetooth accessories; Reconnect brings back a drive
  that was ejected but is still plugged in.
- Startup lists everything macOS starts automatically: apps that open at
  login and background items apps registered, next to launch agents and daemons.

## 1.0.0 (2026-10-24): first public release

- Processes, Performance (CPU, Memory, Disk, Network, GPU, Energy, Sensors),
  Local AI, History, Startup, Users and Services, plus a menu bar monitor.
- Drives: a page per plugged-in drive, Drive Doctor, Storage (Optimize,
  Analyze, Clean; drive Trash and helper files for external drives),
  live transfers with Cancel / Move / Trash, Format, and the Bootable Media
  Creator with Windows setup options.
- Memory: Optimize and Restore, Quit and Reopen with windows, clear cache.
- Network: local IP per interface, router and host names, per-app traffic.
- GPU: rendering / geometry load, memory, temperature, top processes, local AI share.
- Energy: per-app power, battery health, accessories with hubs.
- Battery: charge limit, Charge to 100% Now, schedules, night charging.
- Alerts and history for sustained CPU, memory, swap, heat and disk problems.
