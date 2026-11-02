# Veltrix Anti-Cheat for Garry's Mod

A gamemode-independent anti-wallhack/ESP toolkit with an admin GUI.

## Install
Drop the `veltrix_anticheat` folder into `garrysmod/addons/` and restart. Admins open the panel with `!veltrix` in chat or `veltrix` in console.

## What it does
| Module | Purpose |
|---|---|
| **Anti-ESP** | Per viewer/target line-of-sight checks on top of the engine PVS. Hidden players (and their weapons) are not transmitted at all, so there is nothing for a wallhack to read. Includes hold time, movement/ping lookahead and a trace budget to limit pop-in and CPU cost. |
| **Honeypot decoys** | Roaming bot players placed behind walls near one player at a time (inside their PVS, out of their sight, sent only to them). Player-ESP draws them like real enemies. Tracking one through walls or firing at one scores strong points. Checked on every usercmd, so one-tick silent aim is caught too. Static prop mode is also available. |
| **Aim analysis** | Silent aim (psilent) pattern: one-tick view spike while firing that snaps back next tick. Also: view turns with zero mouse input, and snap-then-hit (weak). |
| **Suspicion system** | Everything reports into one per-player score with decay, an event log (saved to `data/veltrix/log.txt`), admin alerts, whitelist, and optional auto kick/ban (off by default). |
| **Private data API** | `Veltrix.PD.Set(owner, key, value, recipients)` / `Veltrix.PD.Get(ent, key, default)`: send secrets (roles, ammo, custom health bars) only to who needs them instead of using global NWVars. |

## First-time setup
1. Join the server as an admin, open `!veltrix`, go to **Settings** and turn **Exempt admins** off while testing (otherwise admins see everything and aren't scored).
2. Honeypot bot mode needs no setup but uses `hp_count` free player slots (default 2). Static mode needs spots in open, hidden space (never inside solid walls).
3. Watch **Players** and **Events** for a while before enabling any auto action.

## Permissions
Default: admin = view / kick / reset / whitelist, superadmin = settings / ban / spots / clear log.
Override with CAMI/ULX/SAM:
```lua
hook.Add("Veltrix_CanAccess", "mine", function(ply, level) -- level: "admin" or "super"
    return ply:query("veltrix_" .. level)
end)
```

## Hooks for developers
- `Veltrix_Event(ply, entry)`: every suspicion event.
- `Veltrix_Flagged(ply, score, entry)`: score crossed the alert threshold (wire into Discord webhooks etc.).
- `Veltrix_ForceVisible(viewer, target)`: return `true` to always transmit (cameras, mirrors, spectator tools).
- `Veltrix_GetAttached(ply)`: return a table of extra entities that should be hidden with the player.
- `Veltrix.Suspect(ply, "tag", points, "detail")`: report your own detections.
- `Veltrix.RevealEntity(ent)`: unhide an entity for everyone (custom weapon drops).

## Known limits
- Cannot stop aimbots/triggerbots that only use information a player legitimately has.
- Decoy bots appear in `player.GetAll()`, the scoreboard and player counts, and fire PlayerInitialSpawn for other addons. Use `Veltrix.IsDecoy(ply)` to skip them in your own code. A cheat that ignores bots will not see them.
- Silent-aim detection catches the classic one-tick spike. A cheat that smooths its angles or avoids the spike pattern needs the honeypot (or other evidence) instead. Addons that rewrite view angles (recoil, vehicles) can trip the aim checks; use `Veltrix.IgnoreAim(ply, seconds)` or raise the thresholds.
- Anything you still network globally (NWVars, net messages, sounds) can be read. Use `Veltrix.PD` and check your gamemode.
- Players inside the hold time, lookahead margin or PVS+LOS window can still be seen briefly; that is the cost of avoiding pop-in.
- Cameras/RT scopes/portals that rely on `AddOriginToPVS` need an `Veltrix_ForceVisible` rule.
- Scores are evidence for review, not proof. Keep auto-ban off unless you have tuned thresholds on your own server.
