# Nap

A small macOS menu bar app with one window, Show Me: a table of what your Mac does about sleep.

|            | lid open                        | lid closed                       |
|------------|---------------------------------|----------------------------------|
| plugged in | e.g. never sleeps (display on)  | e.g. sleeps at once              |
| on battery | e.g. sleeps after 10 min idle   | e.g. stays awake 60 min, then sleeps |

Each cell is read from `pmset -g custom` (and Nap's own lid rules). Cells that differ from macOS's default are marked. Click a cell for its choices:

- Lid open: never sleep when idle, or sleep after N min idle. Shows the command (`sudo pmset -c sleep 0`, `sudo pmset -b displaysleep 10 sleep 10`, ...) and applies it through the standard macOS admin prompt. Nap never sees or stores your password.
- Lid closed: sleep at once (macOS default), or stay awake N min then sleep. Plugged in also offers stay awake with no limit. Each power source has its own rule.

Below the table, only when it applies: the countdown ("Closed 14:02 → sleeps 15:02") and apps keeping the Mac awake right now.

The menu has Show Me…, Open at Login, Uninstall Nap… and Quit Nap. Open at Login is turned on the first time Nap.app runs; untick it to stop. The icon shows the state.

## Build and run

```sh
swift test
swift build -c release
.build/release/Nap
```

To share it, `./dmg.sh` builds `.build/dist/Nap.dmg`: Nap.app for Apple silicon and Intel, signed with your Developer ID. With an App Store Connect API key in `ASC_KEY_ID`, `ASC_ISSUER` and `ASC_P8`, it is notarized too, so it opens on other Macs without a warning. The app keeps its settings under `stream.cross.nap`, not `Nap` as the bare binary does.

## How the lid rules work

macOS sleeps the moment the lid closes unless `pmset -a disablesleep 1` is already set. So:

- Lid open: Nap holds `disablesleep 1` only while the current power source's lid-closed rule is to stay awake.
- Lid closed: the current source's rule applies, counted from when the lid closed. If the power source changes, the new source's rule takes over (still counted from the close); if its time is already up, or its rule is sleep at once, the Mac sleeps.
- Hot (thermal state serious or critical), or on battery under 15%, with the lid closed: sleep now.
- Sleep means `disablesleep 0`, then `pmset sleepnow`. When the lid opens again, the rule is held again.
- Quit: `disablesleep 0` if Nap set it. If Nap was killed while holding it, it puts it back at the next launch.

Nap listens for events (lid, power source, battery, heat). It does not poll. The window refreshes when it opens or comes to the front, and on lid and power changes.

## One-time permission

The lid rules run `pmset` as root without a password (a prompt in a bag helps nobody). The first time you pick a stay-awake lid option, the cell shows this file and an Allow… button; the admin prompt writes it to `/etc/sudoers.d/nap` (your user name in place of `you`):

```
# Written by Nap. Lets you run only these commands as root, without a password.
you ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow
```

It is written under a name sudo ignores, owned by root, mode 0440, checked with `visudo -cf`, then moved into place. Nap runs `sudo -n /usr/bin/pmset ...`; `-n` fails rather than asks. If it fails, Nap says so and that rule goes back to sleep at once.

To remove it: `sudo pmset -a disablesleep 0; sudo rm /etc/sudoers.d/nap`.

## Limits

- While a stay-awake rule holds sleep off, the Mac does not idle-sleep on that power source either (the cell says so).
- Lid-closed behaviour can only be tested by closing the lid. Try it on a desk first with a short time.
- Heat: a Mac awake in a bag can get hot. Nap stops at the serious thermal state, but use short times.
- If Nap is force-killed (`kill -9`) or crashes while holding sleep off, sleep stays off until Nap starts again or you run `sudo pmset -a disablesleep 0`.
- `--snapshot DIR` renders the window to PNGs without running any root step (for checking the UI).
