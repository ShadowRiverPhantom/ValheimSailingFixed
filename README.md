# Valheim Sailing Fixed

[Sailing](https://github.com/blaxxun-boop/Sailing) by **blaxxun**, adapted to the current Valheim
build.

## Why this exists

The upstream mod has not been adapted to Valheim 1.0 yet. The 1.0 release added a `bool log`
parameter to `Character.Message`, and the released 1.1.8 `Sailing.dll` still calls the old
four-parameter overload, so every message the mod shows about the sailing skill dies with a
`MissingMethodException`: the text never appears and the interaction throws. It only happens when
the skill is too low, which is why it never shows up in a log at startup.

`build.ps1` rewrites those call sites to the current overload and writes a drop-in `Sailing.dll`.
Nothing else is touched - same version, same patches, same settings, same behaviour.

## What the mod does

- Adds a **Sailing** skill that levels up while you sail
- Higher skill gives the ships you build more hit points and makes the ships you command faster
- Increases your exploration radius while you are on a ship
- Per-ship speed configuration, including ships added by other mods
- Optionally locks ship speeds to specific skill levels
- **Left Shift** while interacting with a ship's ladder nudges the ship
- Can be installed on a server to enforce the configuration

## Upstream

The mod itself is entirely the work of **blaxxun**:
<https://github.com/blaxxun-boop/Sailing>

This repository only carries the adaptation to Valheim 1.0.
