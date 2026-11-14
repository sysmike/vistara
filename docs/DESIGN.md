# Vistara interface specification

How Vistara looks and behaves. UI pull requests are reviewed against this page.
Each rule names the page of Apple's Human Interface Guidelines (HIG) it rests
on; rules marked *judgment* are ours.

## Point of view

Vistara is a quiet utility. The remote desktop is the content, and everything
else stays out of its way. The one thing it should be remembered for: **a
session is just a Mac window**. It has a standard title bar, it resizes, it
goes full screen, it appears in the Window menu and Mission Control, and it
has no chrome of its own.

Consequences:

- System components everywhere. No custom window frames, title bars, or
  controls (HIG Windows: "Avoid creating custom window UI").
- No brand color. The accent color is the one the user chose in System
  Settings (HIG Sidebars: "make sure your sidebar icons display the color
  people choose").
- No in-app appearance switch, no custom blur or translucency. Standard
  components pick up the system's materials on their own, Liquid Glass on
  macOS 26 included. The one custom surface is the reconnecting panel, which
  floats over the remote picture: regular Liquid Glass on macOS 26, a system
  material before (HIG Materials).
- Notices above the connection list belong to the content, not the toolbar:
  on macOS 26 an inset, rounded callout below the toolbar's glass, never a
  band of bar material beneath it (HIG Layout); before macOS 26, a bar band
  with a divider.

## Windows

| Window | Kind | Notes |
| --- | --- | --- |
| Connections | Primary, one per app | Sidebar, connection list, toolbar with search. Reopened with Window > Connections |
| Session | One per connection in use, alone or as a tab | Title is the connection name, subtitle is the host. No toolbar: the desktop fills the window below the title bar. See Session tabs |
| Settings | Auxiliary | Fixed toolbar with panes General, Keyboard, Security |

- Opening a connection opens a new window, because the point is to keep the
  library and several desktops visible at once (HIG Windows: "Choose the right
  moment to open a new window").
- Connecting to a connection that already has a window brings that window
  forward instead of opening a second one. *Judgment.*
- Windows restore their size and position. Nothing important lives in a bottom
  bar (HIG Windows: "Avoid putting critical information or actions in a bottom
  bar").

### Connections window

```
┌──────────────────────────────────────────────────────────────────┐
│ ● ● ●  [sidebar]            Connections      [+]   [ Search    ] │
├───────────────┬──────────────────────────────────────────────────┤
│ All           │ Name            Host                 Last Used   │
│ ★ Favorites   │ ──────────────────────────────────────────────── │
│ ◷ Recents     │ ▣ Build Server  build01.example.com  Today       │
│               │ ▣ Finance VM    10.0.4.17            Yesterday   │
│ Folders       │ ▣ Jump Host     jump.example.com     3 Nov       │
│  ▸ Office     │                                                  │
│  ▸ Lab        │                                                  │
│               │                                                  │
│ Tags          │                                                  │
│  # prod       │                                                  │
│  # test       │                                                  │
└───────────────┴──────────────────────────────────────────────────┘
```

- `NavigationSplitView` with a sidebar and a table. The table has sortable
  columns; a narrow window drops Last Used first, then Host.
- The sidebar shows two levels at most: section headers and their items.
  Folders do not nest (HIG Sidebars: "show no more than two levels of
  hierarchy").
- Nothing actionable sits at the bottom of the sidebar. New Connection is a
  toolbar button and a File menu command (HIG Sidebars: "Avoid putting critical
  information or actions at the bottom of a sidebar").
- The sidebar can be hidden with the toolbar button and View > Hide Sidebar,
  and collapses on its own when the window gets narrow (HIG Sidebars).
- Sidebar icons are SF Symbols in the accent color. Tags are shown by name; a
  tag never relies on color alone (HIG Accessibility).
- File > New Folder makes "New Folder" and puts its name in edit, as Finder
  does. Rename Folder and Delete Folder are in the folder's context menu and
  the Edit menu. Deleting a folder asks nothing: its context menu says
  beforehand that its connections stay in All Connections, and Undo brings
  the folder back with them.
- Connections are dragged onto a folder to move them, or onto Favorites.
  Edit > Move to Folder does the same from the keyboard, and Undo reverses a
  move. Favorites show a star next to the name, a shape and not a colour.
- Recents shows the 20 connections used last, newest first, until the table
  is sorted otherwise.
- Search is a toolbar search field that filters the list as you type, across
  name, host, user, and tags.
- Double-click or Return connects. Empty states say what to do next: "No
  Connections" with a New Connection button; "No Results for “query”".
- When some saved connections or folders cannot be read, the rest load and a
  notice above the list says how many were left out and where the original
  file was copied, with Show in Finder and Close. It is not an alert, because
  nothing is lost and the app is starting. A file that cannot be read at all
  is moved aside and the list starts empty, as before. The passwords of
  connections left out, or in a file moved aside, stay in the Keychain as
  long as the copy is kept; once it is deleted, they go with the next cleanup.

### Connection editor

A sheet on the Connections window, grouped like a System Settings form.

```
┌──────────────────────────────────────────────────┐
│  General                                         │
│    Name          [ Build Server               ]  │
│    Host          [ build01.example.com ] : [3389]│
│    User          [ alice              ]          │
│    Domain        [ EXAMPLE            ]          │
│    Folder        [ Office            ⌄]          │
│    Tags          [ prod ] [ ci ] [          ]    │
│  Display                                         │
│    Resolution    [ Match Window      ⌄]          │
│    ☑ Optimize for Retina displays                │
│  Devices and Audio                               │
│    ☑ Share clipboard                             │
│      ☐ Copy files                                │
│    ☑ Print on this Mac                           │
│    Sound         [ Play on This Mac  ⌄]          │
│  Shared Folders                                  │
│    📁 Transfer  ~/Transfer       ☐ Read only  ⊖  │
│    [ Add Folder… ]                               │
│  Security                                        │
│    ☑ Reconnect if the connection drops           │
│    ☑ Require Network Level Authentication        │
│    Certificate   [ Ask on First Use  ⌄]          │
│                                                  │
│                         [ Cancel ]  [[ Save ]]   │
└──────────────────────────────────────────────────┘
```

- These are per-connection options, so they live here and not in Settings
  (HIG Settings: "prefer letting people modify task-specific options without
  going to your settings area").
- Pop-up buttons and checkboxes over free text wherever the choices are known.
  Host and port validate as you type; the message appears under the field.
- There is no password field. The password is asked for when connecting and
  kept in the Keychain if the user agrees.
- A choice that weakens security shows one line of explanation beneath it.
- Return saves, Escape cancels, Tab order follows the visual order.
- Problems show once a field has been edited, so a new, empty connection
  does not open with a list of complaints. *Judgment.*
- Shared folders are a section of their own, because each folder has its own
  Read only checkbox and its own button to stop sharing it. Add Folder… opens
  the standard open panel and may add several folders at once. A folder that
  can no longer be found says so in its row, and is not shared.
- Edit > Delete Connection (Command-Delete) is named for what it deletes,
  because Edit > Delete already deletes text. In a text field Command-Delete
  keeps its usual meaning. A deleted connection's Keychain item is removed at
  the next launch or quit, when Undo can no longer bring the connection back.

### Session window

The content area shows exactly one of these states. None of them is an alert.

| State | Content |
| --- | --- |
| Connecting | Progress indicator, "Connecting to Build Server…", Cancel button. Appears at once |
| Connected | The remote desktop, edge to edge |
| Reconnecting | The last frame, dimmed, with "Reconnecting…", Cancel, and Reconnect Now |
| Disconnected | What happened, what to do, and one or two buttons (see Errors) |

Sheets on the session window, each a single short task with Cancel:

- **Credentials**: user, domain, password, "Remember this password in my
  keychain". The default button is Connect. The password field starts empty.
- **Unknown certificate** (first use): host, who issued it, validity dates,
  and the SHA-256 fingerprint in selectable monospaced text. Buttons: Cancel,
  Trust Once, Always Trust. The default button is Cancel. *Judgment: trusting
  should take a deliberate click.*

One alert:

- **Changed certificate**. Title: "The identity of “Build Server” has
  changed." Text explains that this can mean the server was reinstalled or
  that someone is intercepting the connection, and shows the remembered and
  the new fingerprint. Buttons: Cancel, and Connect Anyway in the destructive
  style. No default button, so Return does nothing (HIG Alerts: "If you want to
  encourage people to read an alert and not just automatically press Return to
  dismiss it, avoid making any button the default button"). The caution symbol
  is used here and nowhere else (HIG Alerts: "Use a caution symbol sparingly").

Closing a session window disconnects without asking. The remote session keeps
running on the server and Reconnect brings it back, so there is nothing to
lose and nothing to confirm (HIG Alerts: "Avoid displaying alerts for common,
undoable actions"). Quitting with sessions open asks once, with a checkbox to
stop asking. *Judgment.*

### Desktop size

- By default the remote desktop follows the window: a quarter of a second
  after the window's size has rested, the remote computer is asked for a
  desktop that fills it pixel for pixel. Until the answer arrives the picture
  is scaled, so the window resizes fluidly (HIG Windows: "adapt fluidly to
  different sizes").
- On a Retina display the desktop gets every pixel and is told to draw at
  200 percent, so text is sharp and as large as on the Mac. Moving the window
  to a display of another density asks again.
- A connection can instead keep a fixed size, or keep the size it connected
  with. Both are scaled to fit the window, never stretched.
- A remote computer that cannot change its desktop size is not asked twice;
  its desktop is scaled to fit.

### Full screen

- The system's full-screen mode only: the green button, View > Enter Full
  Screen, or Control-Command-F (HIG Going full screen: "Use the
  system-provided full-screen experience").
- The menu bar appears when the pointer reaches the top edge; the Dock and
  Mission Control stay reachable.
- A session stays in full screen until the user leaves it, including after a
  disconnect (HIG Going full screen: "Let people choose when to exit
  full-screen mode").
- AppKit adds no full-screen item to a SwiftUI app's View menu, so Vistara
  provides View > Enter Full Screen itself, for the session in the main
  window. It reads Exit Full Screen while in full screen.
- Session > Disconnect closes the window, as closing does, and so also leaves
  full screen. A session that ends any other way (dropped, refused, timed
  out) keeps its full-screen window and shows what happened there.

### Session tabs

Several sessions can share one window as tabs, with the system's own window
tabbing (HIG The menu bar: Show Previous Tab, Show Next Tab, Move Tab to New
Window, Merge All Windows, Show Tab Bar). Each tab is still a session window
with everything above; tabbing only changes how they are grouped.

- Only session windows group as tabs, never with the Connections window or
  Settings.
- Where a new session opens follows the system setting "Prefer tabs when
  opening documents" (Desktop & Dock): Always opens it as a tab of the session
  window in front; In Full Screen does so when that window is in full screen;
  Never opens a window of its own. Holding Option while connecting does the
  other: File > Connect becomes Connect in New Tab or Connect in New Window.
  *Judgment: the system setting is the user's stated preference, and Option is
  how Mac apps offer the alternate.*
- The tab bar has no + button. A new tab needs a computer, and choosing one
  is what the Connections window is for. *Judgment.*
- Connecting to a computer whose session is a background tab selects that
  tab, as it brings a window forward.
- Closing a tab disconnects that session only, without asking, as closing a
  window does. In a tabbed window File > Close becomes Close Tab
  (Command-W), and Close Window (Shift-Command-W) closes all of its tabs (HIG
  The menu bar, File menu). Quitting still asks once for all open sessions.
- A tab group has one size. The tab in front follows it as a window does; a
  background tab keeps its last picture, scaled, and asks for the new size
  when it comes to the front.
- A session that cannot be seen (a background tab, a minimized window, a
  window entirely covered) stays connected but asks the server to stop
  sending its screen, and asks for it again when it can be seen
  ([MS-RDPBCGR] 2.2.11.3, Suppress Output). Sound keeps playing; only the tab
  in front is offered the Mac's clipboard, as only the window in front is.
- The tab's title is the connection's name. A session that is connecting or
  reconnecting shows a small progress indicator on its tab; one that has
  ended shows a symbol. Both have accessibility labels, and VoiceOver
  announces a background tab's lost connection with the connection's name.
- A tabbed window enters full screen as a whole; the tab bar appears with
  the menu bar at the top edge.
- Size and position are remembered per computer only for a session alone in
  its window. A tab group keeps the frame it has.

### Multiple displays

A session can use every display of the Mac, as one remote desktop that spans
them, the way Windows uses several monitors. Vistara says *displays*, as the
Mac does; *monitors* is the remote computer's word.

- The Display section of the connection editor has **Displays: This Display**
  (the default) or **All Displays**. All Displays shows beneath it that the
  session then always fills the displays in full screen.
- A session on all displays opens in full screen at once, with one window on
  each display, each showing its part of the remote desktop. It is still one
  session: one title in the Window menu and the Dock menu, one Session menu,
  one connection to close. Closing any of its windows, or Session >
  Disconnect, ends it; leaving full screen on any display ends the full screen
  of all of them and the session goes on in one window on the display in
  front, at that window's size. *Judgment: a multi-display desktop in
  windows would be a desktop nobody can see whole.*
- The remote desktop follows the Mac's arrangement in System Settings >
  Displays: the same order and alignment, the Mac's main display (the one
  with the menu bar) as the remote primary monitor, and each display at its
  own pixel density, so a Retina display and a standard one side by side both
  look sharp. Where the Mac's arrangement cannot be copied exactly in whole
  pixels, displays keep touching and their order is kept.
- When a display is added, removed, or rearranged during the session, the
  remote desktop follows, as it follows a window's size. A session left with
  one display goes on in full screen on it.
- Mission Control's "Displays have separate Spaces" must be on, as the
  system's full screen on several displays needs it. When it is off, All
  Displays connects on the display in front only, and the editor says why
  beneath the choice.
- A multi-display session's windows are never tabs, and Option-connecting does
  not change that.
- The keyboard goes to the session while any of its windows is key; the
  pointer moves freely between the displays and the remote computer sees one
  desktop.
- `.rdp` files: `use multimon:i:1` imports as All Displays and exports from
  it. Choosing some displays but not others (`selectedmonitors`) is a later
  step.

### RD Gateway

A connection can go through a Remote Desktop Gateway: the session travels
as HTTPS to the gateway, which passes it on to the computer inside its
network.

- The connection editor has a **Gateway** section: *Use a gateway: Never /
  Always*, the gateway's address (a port other than 443 after a colon), and
  *Sign in to the gateway as: Same as the Computer / Another Account*, with a
  user name and domain for another account. Never is the default and hides
  the rest.
- Only Never and Always. Microsoft's "only when the computer cannot be
  reached directly" and "not for local addresses" are later steps; an
  imported file that asks for them uses the gateway always, and the import
  notice says so. *Judgment: one rule people can predict.*
- Passwords: with Same as the Computer, one password signs in to both and
  one sheet asks for it. With another account, the gateway is asked for
  first, in a sheet of its own that names the gateway and the connection.
  A remembered gateway password is a Keychain item for that gateway and user
  name, so connections through the same gateway share it.
- The gateway's certificate is checked like a computer's (Certificates
  above): one the Mac trusts, as public gateways usually have, connects
  without a question; otherwise the same sheet asks, naming the gateway, and
  Always Trust remembers it for the gateway's address. A changed gateway
  certificate is the same alert. Settings > Security lists gateways beside
  computers, marked as gateways.
- A gateway may show a message before connecting: a notice, or terms the
  user must accept. It appears as a sheet with the gateway's name; consent
  has Accept and Cancel, and Cancel does not connect.
- What goes wrong says which of the two it was: the gateway cannot be
  found, did not accept the user name or password (with Use Another Account
  for the gateway), or does not allow a connection to this computer (its
  resource authorization policy; ask whoever runs it).
- Vistara speaks the gateway's HTTP transport, over WebSocket where the
  gateway offers it. The older RPC-over-HTTP transport (Windows Server 2008)
  and the UDP side channel are not offered.
- Logs replace the gateway's address and user name with placeholders, as
  they do the computer's. Reconnecting goes through the gateway again.
- Not in this step: Azure Virtual Desktop and Microsoft Entra sign-in to the
  gateway, smart cards, and gateway settings shared outside a connection.

## Keyboard

### Who gets a key press

When a session view has keyboard focus:

1. **macOS keeps what it reserves.** Command-Tab, Command-Space, Mission
   Control, and the other system shortcuts never reach Vistara and are not
   intercepted (HIG Keyboards: "Respect standard keyboard shortcuts").
2. **Command belongs to the Mac.** Every Command shortcut in Vistara's menu
   bar runs locally. That means the keyboard is never trapped: Command-W,
   Command-0, Command-Backtick, and Command-Q always work.
3. **Familiar editing shortcuts are translated.** Command-C, V, X, A, Z,
   Shift-Command-Z, F, and S are sent to the remote host as their Control
   equivalents. This is on by default and can be turned off in Settings >
   Keyboard.
4. **Everything else goes to the remote host unchanged**: Control, Option (as
   Alt), Shift, function keys, and Tab.

The Windows key has no Mac counterpart that is free. Session > Send Windows
Key sends it, and Settings > Keyboard offers "Use Right Command as the Windows
key".

With Full Keyboard Access on, Tab inside a session goes to the remote host;
rule 2 is how focus leaves the session.

Between session tabs, Shift-Command-] and Shift-Command-[ show the next and
previous tab (rule 2). Control-Tab and Control-Shift-Tab, the Window menu's
other shortcuts for that, go to the remote computer instead (rule 4), where
Windows apps use them to switch their own tabs. *Judgment.*

Keys are sent by position, not by character: the remote computer's keyboard
layout decides what a key types. To make that layout match the key caps,
Vistara tells the server which layout the Mac's input source is when it
connects (German, French, Japanese, and the other common ones). A server may
start a new session with it; Windows keeps an account's own layout once it
has one. An input source without a clear Windows match leaves the choice to
the server.
A few keys have no exact counterpart. *Judgment:*

- Delete is Backspace, Forward Delete is Delete, and Help is Insert.
- F13 and F14 are Print Screen and Scroll Lock, the keys in those places on a
  PC keyboard.
- A Mac has no Num Lock. The keypad always types digits, and Clear is not
  sent, because it would switch Num Lock off on the remote computer.
- Caps Lock follows the Mac. Its state is stated again whenever the session
  gets the keyboard back.

When the keyboard focus leaves a session, every key the remote computer
believes is held is released, so Command-Tab never leaves a modifier stuck.

### Pointer

- The pointer acts on the remote pixel under it, at any window size and on
  any display. Beside the desktop, in the bars that appear when the window
  has another shape, clicks and moves are not sent; a drag that leaves the
  desktop continues along its edge.
- The first click in an inactive session window only activates it, as in any
  Mac window. *Judgment: an accidental click should not land on a remote
  button.*
- Scrolling follows the system's natural scrolling setting (HIG Settings:
  "Respect people's systemwide settings"). Trackpad distances are sent a
  quarter of a wheel notch at a time, so programs that scroll smoothly follow
  the fingers.
- Over the desktop the cursor is the remote computer's, scaled with the
  desktop. Everywhere else it is the Mac's.
- Control-click is sent as Control and a click, because Control belongs to
  the remote computer. A right click needs the secondary click of the mouse
  or trackpad.

### Menu bar

Every command is in the menu bar, including each toolbar and context menu item
(HIG Designing for macOS: "Use the menu bar to give people easy access to all
the commands they need"). Custom shortcuts are few (HIG Keyboards: "Define
custom keyboard shortcuts for only the most frequently used app-specific
commands").

| Menu | Command | Shortcut | Notes |
| --- | --- | --- | --- |
| Vistara | Settings… | Command-Comma | Standard |
| File | New Connection… | Command-N | Standard "new" |
| File | New Folder | Shift-Command-N | As in Finder |
| File | Connect | Command-O | Standard "open"; also Return and double-click. With Option: Connect in New Tab or New Window (see Session tabs) |
| File | Import… | | Also by opening or dropping a `.rdp` file |
| File | Export… | | |
| File | Close Window | Command-W | Standard; Close Tab in a tabbed session window |
| File | Close Window | Shift-Command-W | Standard; closes the session window in front with all its tabs |
| Edit | Undo, Redo, Cut, Copy, Paste, Select All | Standard | Translated in a session (rule 3) |
| Edit | Edit Connection… | Command-I | Standard "info" |
| Edit | Duplicate | Command-D | Standard |
| Edit | Delete | Command-Delete | As in Finder; undoable |
| Edit | Find | Command-F | Focuses the search field; translated in a session |
| View | Show/Hide Sidebar | Control-Command-S | Standard |
| View | Enter/Exit Full Screen | Control-Command-F | Standard |
| View | Show/Hide Tab Bar, Show All Tabs | Standard | Provided by the system for session windows |
| Session | Reconnect | Command-R | Custom |
| Session | Disconnect | | Same as closing the window |
| Session | Send Ctrl+Alt+Del | Control-Option-Delete | Custom; see below |
| Session | Send Windows Key | | |
| Window | Minimize, Zoom | Standard | |
| Window | Show Previous Tab, Show Next Tab | Shift-Command-[ and ] | Provided by the system; Control-Tab goes to a session (see Keyboard) |
| Window | Move Tab to New Window, Merge All Windows | | Provided by the system, for session windows |
| Window | Connections | Command-0 | As in Mail and Messages |
| Window | *open sessions* | | Provided by the system |
| Help | Vistara Help | Command-? | Standard; opens the user guide in the browser |

Checked against the standard shortcuts in HIG Keyboards: no standard shortcut
is given a different meaning. Control-Option-Delete is free on macOS; using it
means Ctrl+Alt+Backspace cannot be typed directly, which we accept.

The Dock menu lists open sessions, to bring forward, and favorites, to
connect.

### Importing and exporting

- File > Import… adds a connection for each chosen `.rdp` file, named after
  the file, and selects them. Opening an `.rdp` file from the Finder or
  dropping one on the Connections window does the same. Vistara opens `.rdp`
  files as an alternative, never taking them over from the Microsoft client.
- A password in a file is never imported (passwords live only in the
  Keychain). That, lines that aren't settings, and files without a computer
  address are said in a notice above the list, not in an alert.
- File > Export… (also in a connection's context menu) writes the selected
  connections as `.rdp` files the way the Microsoft client writes them,
  never with a password.

### Clipboard

- Text is shared both ways when the connection's Share clipboard is on; when
  it is off the clipboard channel is not loaded at all.
- What the remote computer copies is on the Mac's clipboard at once. What is
  copied on the Mac is offered to the remote computer only while that
  session's window is in front, so it does not leave the Mac until you go
  there. *Judgment.*
- Items marked concealed or transient by password managers (the
  `org.nspasteboard` convention) are never offered.
- Line endings are converted. Images come later; files are below.

### Copying files

Files can go through the clipboard both ways, as in the Finder: copy on one
side, paste on the other.

- The connection's **Copy files** choice, beneath Share clipboard in the
  editor's Devices and Audio, turns it on; it needs Share clipboard and is
  off by default. Settings > General has its default for new connections.
  *Judgment: off by default. While a session is in front, the remote
  computer can read whatever is copied on the Mac without anyone pasting it
  there; for a file, that is all of it. Text is offered the same way, but a
  copied file is often more than anyone meant to share.*
- **Mac to remote computer**: files and folders copied in the Finder or
  another app are offered like text, only while that session's window is in
  front. A folder brings everything in it. Nothing is read until the remote
  computer asks for it, and nothing is read but what was copied: symbolic
  links are not followed.
- **Remote computer to Mac**: files copied there can be pasted in the Finder
  or any app that takes files. They are fetched only when pasted, into a
  folder of Vistara's own, and the app that pastes copies them from there; it
  waits until they are there. Vistara stays responsive while they arrive, and
  a large paste shows its progress and can be cancelled.
- Files from the remote computer are marked as downloaded (quarantined), so
  macOS checks them before anything in them runs. Fetched files are removed
  when the session ends or something else is copied.
- Logs count files; they never name them.
- `.rdp` files have no setting for this, so imports leave it off and exports
  write nothing for it.
- Not in this step: images, dragging files into the session window, and a
  limit on how much can be copied.

### Shared folders

- The remote computer sees only the folders listed in the connection, each as
  a drive named after the folder. Nothing else is ever shared: not the home
  folder, not other disks, and not disks connected later.
- Access survives relaunches through a security-scoped bookmark made when the
  folder is chosen, and is opened only while a session runs.
- A read-only folder can be browsed and read; every request to change it is
  refused, so the remote computer reports that access is denied.
- A folder that cannot be found when connecting is left out; the session
  still starts.

### Printing

Documents printed on the remote computer come out on the Mac, through the
Mac's own print panel.

- The connection's **Print on this Mac** choice, in the editor's Devices and
  Audio, turns it on. It is on by default, for connections saved before it
  existed too, and Settings > General has its default for new connections.
  *Judgment: on, as in Microsoft's client. Printing only brings documents to
  the Mac, and nothing is printed until you confirm it there.* With it off,
  the device redirection channel offers no printer, and is not loaded at all
  without shared folders.
- The remote computer sees one printer, **Vistara**, which prints with
  Windows' own Microsoft Print to PDF driver. No Mac printer is named to it
  and no driver has to be installed: every document arrives as a PDF.
  *Judgment: one printer that is the Mac's print panel, instead of one
  printer for each Mac printer, each needing a matching Windows driver.*
- Each document opens the print panel as a sheet on that session's window,
  with a preview, every printer of the Mac, and the PDF menu to save it
  instead. Cancel throws it away. Documents printed while a panel is open
  wait their turn. If Vistara is not in front, its Dock icon bounces once.
- A document is kept only until it is printed or cancelled, or the session
  ends, and only in a folder of Vistara's own. One larger than 512 MB, or one
  that is not a PDF, is not shown; the session window says so.
- Logs count documents and their size; they never name them or show what is
  in them.
- `.rdp` files keep it: `redirectprinters` is read on import and written on
  export.
- Not in this step: choosing which Mac printers the remote computer sees,
  remote computers without Microsoft Print to PDF (before Windows 10 and
  Windows Server 2016), and printing without the panel.

### Sound

- The connection's Sound choice decides where the remote computer's sound
  goes: Play on This Mac, Play on Remote Computer, or Off. Only Play on This
  Mac loads the sound channel; with the others no sound is sent to the Mac.
- Sound plays through the Mac's default output and moves with it: pick
  headphones in Control Center and the session's sound follows within half a
  second. There is no output picker in Vistara. *Judgment.*
- At most a quarter of a second of sound waits for the output. Anything later
  is dropped, so sound never falls further behind the picture.
- A Mac whose output cannot play costs only the sound; the session goes on.
- Vistara never uses the microphone and never asks for it. Microphone
  redirection is not offered.

## Presentation rules

| Situation | Presentation | Why |
| --- | --- | --- |
| Credentials, unknown certificate, editing a connection | Sheet on the window it belongs to | Short task tied to one window |
| Changed certificate | Alert | Needs attention before anything else happens |
| Connection failed or dropped | In the session window | HIG Alerts: "Avoid using an alert merely to provide information" |
| Deleting a connection or folder | No confirmation; Undo restores it | HIG Alerts: "Avoid displaying alerts for common, undoable actions" |
| Removing a trusted certificate | No confirmation; the next connection asks again | Recoverable |
| App launch | Never an alert | HIG Alerts: "Avoid showing an alert when your app starts" |

A deleted connection's Keychain item is removed only when the deletion can no
longer be undone.

## Settings

Opened with Command-Comma from the app menu; never a toolbar button (HIG
Settings: "Include a settings item in the App menu"). The toolbar is fixed,
the title follows the pane, and the window reopens on the last pane.

| Pane | Contents |
| --- | --- |
| General | Defaults for new connections (resolution, Retina, displays, clipboard, copying files, printing, sound, reconnecting, Network Level Authentication, certificate); whether to ask before quitting with open sessions |
| Keyboard | Translate editing shortcuts; Right Command as the Windows key |
| Security | Trusted certificates: host, fingerprint, date trusted, Remove |

Nothing here repeats a system setting such as appearance, accent color, or
scrolling direction (HIG Settings: "Respect people's systemwide settings").

- The defaults shape only the editor's new connections; saved ones keep what
  they have. A fixed size belongs to one computer and is not a default.
- Right Command as the Windows key is off by default, because Command
  belongs to the Mac (rule 1). When on, Right Command and the keys pressed with
  it go to the remote computer; Left Command stays with the Mac.

## Color, type, and icons

- **Color**: system semantic colors only (label, secondary label, window and
  control backgrounds, separator, accent). No hard-coded values, so light,
  dark, and Increase Contrast work without extra effort. Any color we add
  later needs a contrast figure of at least 4.5:1 against its background.
- **State is never color alone.** A connection's state is a symbol plus text.
- **Type**: system text styles. Fingerprints and technical detail use the
  monospaced system font and are selectable.
- **Icons**: SF Symbols at the weight of the adjacent text. Icon-only buttons
  have a tooltip and an accessibility label.
- **Controls**: standard sizes. Custom hit areas are at least 20 by 20 pt, 28
  by 28 pt by default (HIG Accessibility).
- **Motion**: system transitions only. Nothing animates on its own.
- **App icon**: the same screen again and again, each further away, converging
  on one point: a remote desktop is a screen seen from a distance, the vista
  in the name. A white near frame, an amber and a pale teal frame, and an
  amber screen on a deep indigo to teal gradient. No text, no screenshot, no
  hardware (HIG App icons). `App/Resources/AppIcon.icon`, an Icon Composer
  file, is the one source: three SVG layers (the gradient, the distant
  screens, the frame), with the frame and the distant screens as Liquid Glass.
  In the dark and tinted appearances the gradient gives way to the system's
  background and the screens keep their shapes and colours (HIG App icons,
  Appearances). Xcode makes the icon for macOS 14 and 15 from the same file.

## Accessibility

- Every flow works with the keyboard alone and with Full Keyboard Access (HIG
  Accessibility: "Let people use the keyboard alone to navigate and interact
  with your app").
- VoiceOver reads every control, row, and state change. The session view has
  a label such as "Remote desktop, Build Server". The remote screen itself is
  a picture; reading it is the job of the remote system's own assistive tools,
  and the app says so in its help.
- Reduce Motion, Reduce Transparency, and Increase Contrast are honored by
  using system components and semantic colors. Vistara has no animations of
  its own, and its one material (the reconnecting panel) is a system one:
  Liquid Glass on macOS 26 turns opaque with Reduce Transparency on its own.
- VoiceOver announces when a session connects, is lost and reconnects, or
  ends, with the same words the window shows.
- Words are drawn in the system's label colors only. Red marks a problem
  with its icon, never with its text: red text measures 3.0–3.6:1 on a light
  window. Anything needed to act (what went wrong and what to do, a warning
  that weakens security, a missing folder) is in the primary label color,
  9.7:1 or more. Supplementary text (footnotes, paths, field captions) keeps
  the secondary label color as System Settings does: 5.1:1 or more in dark
  mode, 3.8–4.0:1 in light mode, below 4.5:1, a gap recorded on issue #31.
- Icon-only buttons have a label, a tooltip, and at least 20 by 20 points to
  aim at.

## Wording

- Title-style capitalization for menu items, buttons, and window titles.
  Sentence style for messages and explanations.
- Buttons say what happens: Connect, Trust Once, Always Trust, Reconnect,
  Connect Anyway. Never OK or Yes for an action (HIG Alerts: "Avoid using OK as
  the default button title unless the alert is purely informational").
- Use the words on screen: connection, folder, tag, window, certificate,
  fingerprint, password. Not session object, profile, scene, or credential
  blob.
- Dates are relative in the list ("Today") and complete in details.

### Errors

Every failure has a title that says what happened, one sentence on what to do,
and a button that does it. No bare codes, no "Error", no apology. Technical
detail sits behind a Details disclosure, can be copied, and never contains a
password.

| Situation | Title | Explanation | Buttons |
| --- | --- | --- | --- |
| Name does not resolve | Can't find "build01.example.com" | Check the computer's name, and your network and VPN connection. | Try Again |
| No route | Can't reach "Build Server" | Your Mac has no route to that computer. Check your network and VPN connection. | Try Again |
| No answer | "Build Server" isn't responding | The computer may be off, asleep, or blocked by a firewall. | Try Again |
| Refused | "Build Server" refused the connection | Remote Desktop may be turned off on that computer, or it uses a different port. | Try Again |
| Still starting | "Build Server" is still starting up | Wait a moment, then try again. | Try Again |
| Any other failure to connect | Can't connect to "Build Server" | Check the computer's name and your network connection, and that Remote Desktop is enabled there. | Try Again |
| Wrong credentials | The user name or password is incorrect | | *Returns to the credentials sheet* |
| Password expired | The password for this account has expired | Change it on a computer that can sign in, or ask your administrator, then connect again. | Use Another Account |
| Account not allowed | This account can't sign in remotely | Ask the computer's administrator to allow Remote Desktop for this account. | Use Another Account |
| No common sign-in | "Build Server" requires a kind of sign-in Vistara doesn't support | Ask the computer's administrator which sign-in methods Remote Desktop accepts there. | Try Again |
| Certificate rejected | Connection cancelled | You chose not to trust this computer's certificate. | Try Again |
| Gateway not reached | Can't reach the gateway "gateway.example.com" | Check the gateway's address, and your network and VPN connection. | Try Again |
| Gateway refused the sign-in | The gateway "gateway.example.com" didn't accept the user name or password | Sign in with the account the gateway knows you by. *(Signing in as the computer's account: This connection signs in to the gateway with the computer's account. Try another one.)* | Use Another Account, for the gateway's account or the computer's |
| Gateway refused the computer | The gateway "gateway.example.com" doesn't allow a connection to "Build Server" | Its policy doesn't include this computer. Ask whoever runs the gateway to allow it. | Try Again |
| Ended by the server | "Build Server" ended the session | An administrator or a program on that computer disconnected you. | Reconnect |
| Taken over | Another connection took over this session | The same account connected to "Build Server" from somewhere else. | Reconnect |
| Idle | "Build Server" ended the session after a period of inactivity | Reconnect to continue where you left off. | Reconnect |
| Signed out | You signed out of "Build Server" | Connect again to start a new session. | Connect |
| Network lost | The connection to "Build Server" was lost | Check your network connection, then reconnect. Your session keeps running on the computer. | Reconnect |
| No license | "Build Server" has no Remote Desktop license for this connection | Ask the computer's administrator to check its Remote Desktop licensing. | Try Again |
| Anything else | "Build Server" closed the connection unexpectedly | Try again. If it keeps happening, copy the details below into a bug report. | Try Again |

On screen the quotes and apostrophes are typographic. Edit Connection joins
Try Again where the address or port may be wrong, the gateway's included.
Reconnecting tries a gateway that cannot be reached again, like a computer;
a gateway that refuses the sign-in or the computer ends it.

### Reconnecting

- Only a lost network brings a session back by itself, and only when the
  connection's "Reconnect if the connection drops" is on. A session the
  server, an administrator, or the user ended stays ended.
- Attempts wait 1, 2, 4, 8, 15, and 30 seconds, about a minute in all. When
  the Mac wakes from sleep or its network comes back, the next attempt starts
  at once. Reconnect Now (also Session > Reconnect) does the same by hand.
- Every attempt is a whole new connection: the certificate is checked again,
  so a changed certificate stops with its warning, and a password that is not
  saved is asked for again. A refused password or a "no" ends reconnecting.
- Cancel, or closing the window, stops at once. If no attempt succeeds, the
  window says the connection was lost and that Vistara could not reconnect,
  with Reconnect.
