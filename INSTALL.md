# Installing Upright on your Mac

Upright remaps the buttons on a Logitech MX Vertical. You build it yourself from this folder.
That takes a few minutes and needs no Apple account.

## What you need

- macOS 13 Ventura or newer
- **Xcode 15 or newer**, free from the Mac App Store. Open it once after installing so it can
  finish setting up.
- Your MX Vertical, connected by its receiver, its USB cable, or Bluetooth

## 1. Unzip

Double-click `Upright-macos-source.zip`. You get a folder called `Upright-macos-source`. Move it
anywhere you like, for example to your Documents folder.

## 2. Build and run

**Option A: Xcode (easiest)**

1. Open the folder and double-click `Upright.xcodeproj`.
2. If Xcode asks whether to trust or open the project, click **Open**.
3. Press **⌘R**. A mouse icon appears in the menu bar and the Upright settings window opens.

**Option B: Terminal**

```bash
cd ~/Documents/Upright-macos-source
make app
open build/Build/Products/Release/Upright.app
```

To keep the app, drag `build/Build/Products/Release/Upright.app` into your **Applications**
folder and open it from there.

## 3. Allow Accessibility

Upright needs this to send keyboard shortcuts and media keys for your buttons.

1. Click **Allow…**, either in the menu-bar panel or in Settings → Buttons.
2. In System Settings → Privacy & Security → **Accessibility**, turn **Upright** on.
3. Upright notices the change by itself. You don't need to restart it.

Until you allow it, mapped buttons keep their normal behavior. If macOS ever blocks the mouse
itself, the Permissions pane will ask for **Input Monitoring** too.

Once it's running, the thumb buttons go Back and Forward, and the top button opens Mission
Control. To change them, open the menu-bar icon → **Settings…** → **Buttons**.

## If macOS blocks the app

Upright is **ad-hoc signed**: it isn't notarized by Apple. If macOS says it can't be opened,
right-click `Upright.app`, choose **Open**, then click **Open** again. You only need to do this
the first time.

If Xcode reports that files are quarantined after unzipping, run this once and try again:

```bash
xattr -dr com.apple.quarantine ~/Documents/Upright-macos-source
```

## Quit

Click the menu-bar mouse icon and choose **Quit Upright**, or press ⌘Q while the panel is open.
Your buttons go back to normal straight away.

## Uninstall

1. In Upright → Settings → General, turn off **Open at login** if you turned it on.
2. Quit Upright.
3. Delete `Upright.app` (from Applications, or from the `build` folder) and this source folder.
4. Optional: remove its settings and permissions.

   ```bash
   defaults delete io.github.upright.Upright
   tccutil reset Accessibility io.github.upright.Upright
   tccutil reset ListenEvent io.github.upright.Upright
   ```

Upright never writes anything to the mouse, so nothing needs to be undone there.

For details, troubleshooting and how to test with the mouse, see `README.md`.
