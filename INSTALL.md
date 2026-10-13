# Installing Upright on your Mac

Upright remaps the buttons on a Logitech MX Vertical. You build it yourself from this folder.
That takes a few minutes and needs no Apple account.

## What you need

- macOS 13 Ventura or newer
- **Xcode 15 or newer**, free from the Mac App Store. Open it once after installing so it can
  finish setting up.
- Your MX Vertical, connected by its Unifying receiver, its USB cable, or Bluetooth. (The MX
  Vertical doesn't work with a Bolt receiver.)

## 1. Unzip

Double-click `Upright-macos-source.zip`. You get a folder called `Upright-macos-source`. Move it
anywhere you like, for example to your Documents folder.

## 2. Build and run

**Option A: Xcode (easiest)**

1. Open the folder and double-click `Upright.xcodeproj`.
2. If Xcode asks whether to trust or open the project, click **Open**.
3. Press **⌘R**. A mouse icon appears in the menu bar and a welcome window opens.

**Option B: Terminal**

```bash
cd ~/Documents/Upright-macos-source
make app
open build/Build/Products/Release/Upright.app
```

## 3. Move it to Applications

Drag `build/Build/Products/Release/Upright.app` into your **Applications** folder and open it
from there.

**Do this before you turn on Open at login.** Upright registers itself as a login item from
wherever it is running. A copy in `build/`, in Xcode's DerivedData or in Downloads stops
working as soon as it is moved, rebuilt or deleted. Upright warns you in Settings → General if
it isn't in Applications. If you already turned the option on from another copy, turn it off,
quit, launch the copy in Applications and turn it on again.

## 4. Allow Accessibility

Upright needs this to send keyboard shortcuts, media keys and clicks for your buttons, and to
change scrolling.

1. Click **Allow…**, either in the welcome window, the menu-bar panel or Settings → Buttons.
2. In System Settings → Privacy & Security → **Accessibility**, turn **Upright** on.
3. Upright notices the change by itself. You don't need to restart it.

Until you allow it, mappings that need it are not applied and your buttons keep their normal
behavior. Actions that don't send input (Mission Control, opening apps and links, Shortcuts,
pointer speed) work without it. Upright asks for **Input Monitoring** only if macOS hides the
mouse from it, which can happen over Bluetooth.

If Accessibility shows as on but Upright says it isn't allowed (this happens after you rebuild
or replace the app), open Settings → Permissions and click **Reset Permission**.

**What the buttons do at first.** A fresh install remaps nothing: Back, Forward and the top
button keep their normal behavior. To change them, open the menu-bar icon → **Settings…** →
**Buttons**. If you are upgrading from an earlier version, your old mappings are kept.

## If macOS blocks the app

Upright is **ad-hoc signed**: it isn't notarized by Apple. If macOS says it can't be opened or
that the developer can't be verified:

1. Right-click `Upright.app`, choose **Open**, then click **Open** again. You only need to do
   this the first time.
2. If there is no Open button, go to System Settings → Privacy & Security, scroll down to the
   message about Upright and click **Open Anyway**.
3. If it still refuses, remove the quarantine flag and try again:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Upright.app
   ```

If Xcode reports that files are quarantined after unzipping, run this once and try again:

```bash
xattr -dr com.apple.quarantine ~/Documents/Upright-macos-source
```

## Quit

Click the menu-bar mouse icon and choose **Quit Upright** (also in Settings → General), or
press ⌘Q while the panel is open. Your buttons go back to normal straight away.

## Uninstall

1. In Upright → Settings → General, turn off **Open at login** if you turned it on.
2. Quit Upright.
3. Delete `Upright.app` (from Applications, or from the `build` folder) and this source folder.
4. Optional: export your mappings first (Settings → General → Export…) if you want to keep them.
5. Optional: remove its settings and permissions.

   ```bash
   defaults delete io.github.upright.Upright
   tccutil reset Accessibility io.github.upright.Upright
   tccutil reset ListenEvent io.github.upright.Upright
   ```

Upright never writes anything permanent to the mouse, so nothing needs to be undone there.

## Troubleshooting

Mouse not found, Bluetooth problems, buttons that don't remap, scrolling that doesn't change
and more are covered in the
[Troubleshooting section of the README](README.md#troubleshooting).
