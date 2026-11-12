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
  components pick up the system's materials on their own.

## Windows

| Window | Kind | Notes |
| --- | --- | --- |
| Connections | Primary, one per app | Sidebar, connection list, toolbar with search. Reopened with Window > Connections |
| Session | One per connection in use | Title is the connection name, subtitle is the host. No toolbar: the desktop fills the window below the title bar |
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
- Search is a toolbar search field that filters the list as you type, across
  name, host, user, and tags.
- Double-click or Return connects. Empty states say what to do next: "No
  Connections" with a New Connection button; "No Results for “query”".

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
│    Sound         [ Play on This Mac  ⌄]          │
│    Shared folders  [ ~/Transfer ]  [+] [−]       │
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

### Session window

The content area shows exactly one of these states. None of them is an alert.

| State | Content |
| --- | --- |
| Connecting | Progress indicator, "Connecting to Build Server…", Cancel button. Appears at once |
| Connected | The remote desktop, edge to edge |
| Reconnecting | The last frame, dimmed, with "Reconnecting…" and Cancel |
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

### Full screen

- The system's full-screen mode only: the green button, View > Enter Full
  Screen, or Control-Command-F (HIG Going full screen: "Use the
  system-provided full-screen experience").
- The menu bar appears when the pointer reaches the top edge; the Dock and
  Mission Control stay reachable.
- A session stays in full screen until the user leaves it, including after a
  disconnect (HIG Going full screen: "Let people choose when to exit
  full-screen mode").

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

Keys are sent by position, not by character: the remote computer's keyboard
layout decides what a key types, so the Mac input source does not matter.
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
| File | Connect | Command-O | Standard "open"; also Return and double-click |
| File | Import… | | Also by opening or dropping a `.rdp` file |
| File | Export… | | |
| File | Close Window | Command-W | Standard |
| Edit | Undo, Redo, Cut, Copy, Paste, Select All | Standard | Translated in a session (rule 3) |
| Edit | Edit Connection… | Command-I | Standard "info" |
| Edit | Duplicate | Command-D | Standard |
| Edit | Delete | Command-Delete | As in Finder; undoable |
| Edit | Find | Command-F | Focuses the search field; translated in a session |
| View | Show/Hide Sidebar | Control-Command-S | Standard |
| View | Enter/Exit Full Screen | Control-Command-F | Standard |
| Session | Reconnect | Command-R | Custom |
| Session | Disconnect | | Same as closing the window |
| Session | Send Ctrl+Alt+Del | Control-Option-Delete | Custom; see below |
| Session | Send Windows Key | | |
| Window | Minimize, Zoom | Standard | |
| Window | Connections | Command-0 | As in Mail and Messages |
| Window | *open sessions* | | Provided by the system |
| Help | Vistara Help | Command-? | Standard |

Checked against the standard shortcuts in HIG Keyboards: no standard shortcut
is given a different meaning. Control-Option-Delete is free on macOS; using it
means Ctrl+Alt+Backspace cannot be typed directly, which we accept.

The Dock menu lists favorites and open sessions.

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
| General | Defaults for new connections; whether to ask before quitting with open sessions |
| Keyboard | Translate editing shortcuts; Right Command as the Windows key |
| Security | Trusted certificates: host, fingerprint, date trusted, Remove |

Nothing here repeats a system setting such as appearance, accent color, or
scrolling direction (HIG Settings: "Respect people's systemwide settings").

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

## Accessibility

- Every flow works with the keyboard alone and with Full Keyboard Access (HIG
  Accessibility: "Let people use the keyboard alone to navigate and interact
  with your app").
- VoiceOver reads every control, row, and state change. The session view has
  a label such as "Remote desktop, Build Server". The remote screen itself is
  a picture; reading it is the job of the remote system's own assistive tools,
  and the app says so in its help.
- Reduce Motion, Reduce Transparency, and Increase Contrast are honored by
  using system components and semantic colors.

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
| Name does not resolve | Can't find "build01.example.com" | Check the host name, or your VPN and network connection. | Edit Connection, Try Again |
| No answer | "Build Server" isn't responding | The computer may be off, asleep, or blocked by a firewall. | Try Again |
| Refused | "Build Server" refused the connection | Remote Desktop may be turned off on that computer, or it uses a different port. | Edit Connection, Try Again |
| Wrong credentials | The user name or password is incorrect | | *Returns to the credentials sheet* |
| Account not allowed | This account can't sign in remotely | Ask the computer's administrator to allow Remote Desktop for this account. | Use Another Account |
| Certificate rejected | Connection cancelled | You chose not to trust this computer's certificate. | Try Again |
| Ended by the server | "Build Server" ended the session | Another user may have signed in, or the session timed out. | Reconnect |
| Network lost | The connection was lost | Vistara will reconnect when the network is back. | Reconnect Now |
