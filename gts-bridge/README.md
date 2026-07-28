# GTS Bridge

Client-only Forge 1.12.2 mod that captures Global GTS chat messages, including
their full `ITextComponent` and hover payload.

The mod listens with `EventPriority.HIGHEST` and `receiveCanceled = true`, does
not cancel or replace messages, and has no Pixelmon or other mod dependency.

Captured data is written under the Minecraft game directory:

- `gts-bridge/latest.json`: most recent Global GTS message.
- `gts-bridge/captures.jsonl`: append-only history.
