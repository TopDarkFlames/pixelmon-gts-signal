# GTS Bridge

Client-only Forge 1.12.2 mod that captures Global GTS chat messages in English
or Portuguese, including their full `ITextComponent` and hover payload. It also
integrates with JourneyMap 5.7.1 to maintain a live traveling merchant waypoint.

The mod listens with `EventPriority.HIGHEST` and `receiveCanceled = true`, does
not cancel or replace messages, and has no Pixelmon or other mod dependency.

Captured data is written under the Minecraft game directory:

- `gts-bridge/latest.json`: most recent Global GTS message.
- `gts-bridge/captures.jsonl`: append-only history.

When chat contains `O mercador chegou em <local> nas coordenadas <x> <y> <z>`,
the mod creates or replaces the persistent `Mercador - <local>` waypoint in the
current dimension. The JourneyMap jar is used only as a compile-time API and is
not modified or bundled.

Build with the installed JourneyMap jar or override its location:

```bash
JOURNEYMAP_JAR=/path/to/journeymap.jar ./gradlew build
```
