# Nap

A small macOS menu bar app that:

1. Shows what your sleep settings do, in plain sentences (from `pmset -g custom`), and what is keeping the Mac awake right now (from `pmset -g assertions`).
2. Shows how to change them: a few goals, each with the exact setting and command, and an Apply button that uses the standard macOS admin prompt. Nap never sees or stores your password.
3. Keeps the Mac awake with the lid closed on battery for a set time (default 60 minutes), then puts it to sleep.

## Build and run

```sh
swift test               # unit tests
swift build -c release
.build/release/Nap       # moon icon appears in the menu bar
```

Menu: Show Me… opens the window. Quit Nap quits (and turns sleep back on if the lid timer was armed).

## The lid timer

macOS sleeps the moment the lid closes, unless `pmset -a disablesleep 1` was set before. So:

- Arming sets `disablesleep 1`.
- Lid closed on battery: the countdown starts. Lid opened: it is cancelled; the next close gets the full time again.
- Lid closed and plugged in: stays awake, countdown paused. Unplugging resumes it with the time left.
- Time up, Mac hot (thermal state serious or critical), or battery under the floor (default 15%) while the lid is closed: `disablesleep 0`, then `pmset sleepnow`. Nap stays armed and sets `disablesleep 1` again the next time the lid opens.
- Disarm or quit: `disablesleep 0`, always. If Nap was killed while armed, it turns sleep back on at its next launch.

Nap listens for events (lid, power source, battery, heat). It does not poll.

## One-time permission

The lid timer runs `pmset` as root without asking for a password (a prompt in a bag helps nobody). Menu: **Allow Nap to Change Sleep…** shows this file, then the admin prompt writes it to `/etc/sudoers.d/nap` (your user name in place of `you`):

```
# Written by Nap. Lets you run only these commands as root, without a password.
you ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow
```

It is written under a temporary name sudo ignores, owned by root, mode 0440, checked with `visudo -cf`, and only then moved into place. Nap then runs `sudo -n /usr/bin/pmset ...`; `-n` means it fails rather than asks. If it fails, Nap says so and does not arm.

**Remove Nap's Permission…** runs `pmset -a disablesleep 0` and deletes the file, through the admin prompt.

## Limits

- While armed, the Mac does not sleep at all, lid open or closed, except when Nap puts it to sleep.
- Lid-closed behaviour can only be truly tested by closing the lid. Try it first on a desk, with a short duration (15 minutes).
- Heat: a Mac awake in a closed bag can get hot. Nap stops early at the serious thermal state, but a bag can still trap heat. Use a short time.
- If Nap is force-killed (`kill -9`) or crashes while armed, sleep stays off until Nap starts again or you run `sudo pmset -a disablesleep 0`.
- The admin prompt and the sudoers file are only touched when you click; Nap never installs anything on its own.
