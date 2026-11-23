# Lid

Lid lets you choose when your Mac goes to sleep, even with the lid closed. A Mac normally goes to sleep the moment you close it. With Lid, it can keep running a download, a build or a call in your bag, for an hour say, and then sleep. It also sleeps early if it gets hot or the battery runs low, so a Mac left on in a bag doesn't cook.

![Lid's window: when this Mac goes to sleep, plugged in or on battery, with the lid open or closed](screenshots/show-me.png)

## Install

Download `Lid.dmg` from the [latest release](https://github.com/cablehead/lid/releases/latest), open it, and drag Lid to Applications. It runs on macOS 14 or later.

Lid lives in the menu bar, as a closed laptop under a sun. The sun is filled while Lid is keeping your Mac awake, or will keep it awake when you close the lid.

## Show Me

Click the sun and choose Show Me. Each box covers one case: plugged in or on battery, with the lid open or closed. A box that isn't at macOS's usual setting says "not macOS default".

Below the boxes, Lid lists what is keeping your Mac awake right now, such as music playing, and when it will sleep if the lid is closed.

## Lid closed

Click Change in a "lid closed" box and pick how long it stays awake before it sleeps, from a minute to a week. Plugged in, it can also stay awake until you open the lid again. The two "lid closed" boxes keep their own times, so it can stay awake for an hour plugged in and ten minutes on battery.

The first time, Lid asks for your password, once, and uses it to write `/etc/sudoers.d/lid`. That file lets Lid run three commands as root without asking again, and nothing else:

```
# Written by Lid. Lets you run only these commands as root, without a password.
you ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow
```

Lid runs them on its own, at moments nobody is there to type a password. It turns sleep off while the lid is open, so the Mac stays awake when you close it. When your time is up, it turns sleep back on and puts the Mac to sleep. It puts the Mac to sleep early if it gets hot or the battery drops under 15%; a Mac in a bag can get hot. If you plug in or unplug with the lid closed, the other box's time takes over, still counted from when you closed the lid.

While Lid is keeping your Mac awake with the lid closed, it doesn't sleep when idle with the lid open either. The box says so.

Try it on a desk first, with a short time, before trusting it in a bag.

## Lid open

Click Change in a "lid open" box. Lid shows the command it will run, such as `sudo pmset -c sleep 0`, and macOS asks for your password to run it. Lid never sees or keeps that password.

## Amphetamine and caffeinate

Amphetamine can keep a Mac awake with the lid closed too. Once the lid is closed, it doesn't watch for heat, and its users ask for that after finding their Mac hot in a bag. Lid sleeps the Mac when it gets hot, when the battery drops under 15%, or when your time is up. `caffeinate` keeps a Mac awake while it's open, but not with the lid closed on battery.

## Uninstall

Choose Uninstall Lid in the menu. It turns sleep back on, removes `/etc/sudoers.d/lid`, deletes Lid's settings, and moves Lid to the Trash. To do the same by hand:

```sh
sudo pmset -a disablesleep 0; sudo rm /etc/sudoers.d/lid
```

If Lid crashes or is force quit while it has sleep turned off, sleep stays off until Lid starts again. The first half of that command turns it back on.

## Build

```sh
swift test
swift build -c release
.build/release/Lid
```

`./dmg.sh` builds `.build/dist/Lid.dmg` for Apple silicon and Intel, signed with your Developer ID. With an App Store Connect API key in `ASC_KEY_ID`, `ASC_ISSUER` and `ASC_P8`, it is notarized too, so it opens on other Macs without a warning.

`.build/release/Lid --snapshot DIR` draws the window to PNG files without changing any setting, for checking how it looks.
