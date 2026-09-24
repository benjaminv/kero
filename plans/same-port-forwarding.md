# Plan: forward a remote port to the same local port when it is free

> Working note for this branch. Delete this file before opening a PR.

## Problem

Clicking a remote port in the Info panel forwards it to a **random** loopback port
(`RemoteConnection.freeLocalPort()` binds port 0). That works for a self-contained
server, but breaks any dev server whose pages hardcode their own port.

Real case (2026-09-24): Shopify theme dev (`dawn`) on the A1 host.

| Remote | What it serves | What happens with a random local port |
|---|---|---|
| 9292 | theme preview (Shopify CLI proxy) | opens fine at `127.0.0.1:5xxxx` |
| 5173 | Vite assets + HMR websocket | page asks for `http://localhost:5173/@vite/client` → nothing there → no JS/CSS, no HMR |

The fix: when forwarding remote port N, try local port N first and fall back to a
free port only if N is taken locally. That behaves like the user's hand-written
`ssh -L 9292:127.0.0.1:9292 -L 5173:127.0.0.1:5173`, which is confirmed to work
end to end, HMR included.

## Where the code is

- `kero/RemoteConnection.swift`
  - `forward(remotePort:)` (~L192): calls `Self.freeLocalPort()`, then
    `ssh -O forward -L 127.0.0.1:<local>:127.0.0.1:<remote>`.
  - `freeLocalPort()` (~L228): bind port 0 on loopback, read it back, close.
- `kero/RemoteCommands.swift` (~L34): a **second**, `UInt16` copy of
  `freeLocalPort()` plus `forwardSpec` / `forwardArguments` builders and asserts
  (~L520). `RemoteConnection` does not use these builders. Decide whether to keep
  both copies; don't make them diverge further.
- `kero/PortForwardController.swift`: caches remote→local per connection. No change
  needed; it just stores whatever `forward` returns.
- `kero/RightSidebarView.swift`
  - `withForwardedURL` (~L2677) builds `http://127.0.0.1:<local>/`.
  - `InfoPortRow` (~L2860): label shows `"<remote> → <local>"` whenever a local port
    exists.

## Steps

1. **Add a "can I bind this exact port" helper** next to `freeLocalPort()` in
   `RemoteConnection.swift`: bind `127.0.0.1:<port>`, report success or failure, then close.
   - Do **not** set `SO_REUSEADDR`. We want `EADDRINUSE` when something is listening.
   - Also check `::1` (`AF_INET6`, `IN6ADDR_LOOPBACK_INIT`). `localhost` can resolve to `::1`
     on macOS, so a local process on `[::1]:5173` could win over our IPv4 forward. Treat "busy on either" as busy.
2. **Change `forward(remotePort:)`**:
   - If `remotePort >= 1024` and the probe says it is free, use `remotePort`.
     Ports below 1024 can't be bound without root, so skip straight to the fallback.
   - Otherwise use `freeLocalPort()` as today.
   - If `ssh -O forward` fails on the preferred port (someone grabbed it between
     probe and forward), retry **once** with `freeLocalPort()` instead of surfacing an alert.
   - Update the doc comment. "Allocates a local listener" should say it prefers the same
     number and why: pages that hardcode their own port, such as the Vite client.
3. **Row label** (`InfoPortRow.portLabel`): when `localPort == port.port`, show
   `9292` plus the existing forwarded icon, not `9292 → 9292`. Keep `a → b` for
   the fallback case so a mismatch is obvious.
4. **Leave `cancelForward` as it is.** It already rebuilds the spec from the stored
   `localPort`, so it works for both paths.
5. **Asserts** in `RemoteCommands.swift` self-test (~L534): add a probe case
   (bind a socket to a port, check the probe reports it busy, close, check it reports free).

## Out of scope (note, don't build yet)

- **"Forward all" or auto-forwarding a companion port.** The dawn case still needs
  *two* clicks (9292 and 5173), since forwarding is deliberately never automatic
  (see the `f596a0b4` commit message). If that gets annoying, a later option is a
  per-project list of ports to forward on connect.
- **Custom local port.** Picking a specific local port through a "Forward as…" menu item.

## Verify on the Mac

1. Build: `xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`
2. In a Kero pane, `ssh` to the A1 host, then run
   `cd ~/Documents/__Codes__/Ben/dawn && pnpm run dev` (store password `dawn`).
3. In the Info panel, open 9292, then open 5173. Both rows should show plain `9292` and `5173`.
4. Browser at `http://127.0.0.1:9292`: page styled, no console errors for
   `localhost:5173`. Save a change to `src/theme/templates/index.json` or a CSS
   file and check that it refreshes by itself.
5. **Fallback:** on the Mac, run `python3 -m http.server 5173` first, then open 5173
   in Kero. It should forward to a random port and the row should show `5173 → 5xxxx`.
6. **Disconnect and reconnect:** the forwards drop with the connection. Opening again
   reuses the same local numbers.
7. `lsof -nP -iTCP -sTCP:LISTEN | grep ssh`: every forward is on `127.0.0.1`, never `*`.
