# Lid

A small macOS menu bar app with one window, Show Me: a table of what your Mac does about sleep.

|            | lid open                        | lid closed                       |
|------------|---------------------------------|----------------------------------|
| plugged in | e.g. never sleeps (display on)  | e.g. sleeps at once              |
| on battery | e.g. sleeps after 10 min idle   | e.g. stays awake 60 min, then sleeps |

Each cell is read from `pmset -g custom` (and Lid's own rules for a closed lid). Cells that differ from macOS's default are marked. Click a cell for its choices:

- Lid open: never sleep when idle, or sleep after N min idle. Shows the command (`sudo pmset -c sleep 0`, `sudo pmset -b displaysleep 10 sleep 10`, ...) and applies it through the standard macOS admin prompt. Lid never sees or stores your password.
- Lid closed: sleep at once (macOS default), or stay awake N min then sleep. Plugged in also offers stay awake with no limit. Each power source has its own rule.

Below the table, only when it applies: the countdown ("Closed 14:02 → sleeps 15:02") and apps keeping the Mac awake right now.

The menu has Show Me, Allow Lid to Turn Sleep Off, Open at Login and Quit Lid. Allow Lid to Turn Sleep Off first says what the password is for and that Uninstall Lid takes it back, then shows the admin prompt that writes `/etc/sudoers.d/lid`; once it is there, the same item reads Uninstall Lid instead. Uninstall Lid turns sleep back on, removes that file and the login item, deletes Lid's settings, moves Lid.app to the Trash and quits. Open at Login is turned on the first time Lid.app runs; untick it to stop. The icon is a closed laptop under a sun, like the app icon: the sun is outlined when the Mac will sleep as usual, and filled while Lid keeps it awake or will when the lid shuts.

## Build and run

```sh
swift test
swift build -c release
.build/release/Lid
```

To share it, `./dmg.sh` builds `.build/dist/Lid.dmg`: Lid.app for Apple silicon and Intel, signed with your Developer ID. With an App Store Connect API key in `ASC_KEY_ID`, `ASC_ISSUER` and `ASC_P8`, it is notarized too, so it opens on other Macs without a warning. The app keeps its settings under `stream.cross.lid`, not `Lid` as the bare binary does.

## How the lid rules work

macOS sleeps the moment the lid closes unless `pmset -a disablesleep 1` is already set. So:

- Lid open: Lid holds `disablesleep 1` only while the current power source's lid-closed rule is to stay awake.
- Lid closed: the current source's rule applies, counted from when the lid closed. If the power source changes, the new source's rule takes over (still counted from the close); if its time is already up, or its rule is sleep at once, the Mac sleeps.
- Hot (thermal state serious or critical), or on battery under 15%, with the lid closed: sleep now.
- Sleep means `disablesleep 0`, then `pmset sleepnow`. When the lid opens again, the rule is held again.
- Quit: `disablesleep 0` if Lid set it. If Lid was killed while holding it, it puts it back at the next launch.

Lid listens for events (lid, power source, battery, heat). It does not poll. The window refreshes when it opens or comes to the front, and on lid and power changes.

## One-time permission

The lid rules run `pmset` as root without a password (a prompt in a bag helps nobody). Allow Lid to Turn Sleep Off in the menu, or the Allow button a lid-closed cell shows the first time you pick a stay-awake option, runs the admin prompt that writes it to `/etc/sudoers.d/lid` (your user name in place of `you`):

```
# Written by Lid. Lets you run only these commands as root, without a password.
you ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow
```

It is written under a name sudo ignores, owned by root, mode 0440, checked with `visudo -cf`, then moved into place. Lid runs `sudo -n /usr/bin/pmset ...`; `-n` fails rather than asks. If it fails, Lid says so and that rule goes back to sleep at once.

To remove it: `sudo pmset -a disablesleep 0; sudo rm /etc/sudoers.d/lid`.

## Limits

- While a stay-awake rule holds sleep off, the Mac does not idle-sleep on that power source either (the cell says so).
- Lid-closed behaviour can only be tested by closing the lid. Try it on a desk first with a short time.
- Heat: a Mac awake in a bag can get hot. Lid stops at the serious thermal state, but use short times.
- If Lid is force-killed (`kill -9`) or crashes while holding sleep off, sleep stays off until Lid starts again or you run `sudo pmset -a disablesleep 0`.
- `--snapshot DIR` renders the window to PNGs without running any root step (for checking the UI).
