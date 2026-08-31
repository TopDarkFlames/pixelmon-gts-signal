package br.com.pixelmongts.bridge;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

import org.apache.logging.log4j.Logger;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import net.minecraft.util.text.ITextComponent;
import net.minecraft.util.text.event.HoverEvent;
import net.minecraftforge.client.event.ClientChatReceivedEvent;
import net.minecraftforge.fml.common.eventhandler.EventPriority;
import net.minecraftforge.fml.common.eventhandler.SubscribeEvent;

final class GtsChatCapture {
    private static final Gson COMPACT_GSON = new Gson();
    private static final Gson PRETTY_GSON = new GsonBuilder().setPrettyPrinting().create();

    private final Path outputDirectory;
    private final Path capturesFile;
    private final Path latestFile;
    private final Logger logger;

    GtsChatCapture(Path outputDirectory, Logger logger) {
        this.outputDirectory = outputDirectory;
        this.capturesFile = outputDirectory.resolve("captures.jsonl");
        this.latestFile = outputDirectory.resolve("latest.json");
        this.logger = logger;
    }

    @SubscribeEvent(priority = EventPriority.HIGHEST, receiveCanceled = true)
    public void onChat(ClientChatReceivedEvent event) {
        ITextComponent message = event.getMessage();
        if (message == null) {
            return;
        }

        String unformatted = message.getUnformattedText();
        MerchantAnnouncement.parse(unformatted).ifPresent(MerchantWaypointManager::updateWaypoint);

        if (!isGlobalGtsMessage(unformatted)) {
            return;
        }

        JsonObject capture = createCapture(event, message, unformatted);
        try {
            writeCapture(capture);
            logger.info(
                "Captured marketplace component with {} hover event(s)",
                capture.getAsJsonArray("hoverEvents").size()
            );
        } catch (IOException exception) {
            logger.error("Could not persist Global GTS capture", exception);
        }
    }

    private static boolean isGlobalGtsMessage(String message) {
        String normalized = message == null ? "" : message.toLowerCase(Locale.ROOT);
        return normalized.contains("to the global gts for")
            || normalized.contains("ao gts global por");
    }

    private static JsonObject createCapture(
        ClientChatReceivedEvent event,
        ITextComponent message,
        String unformatted
    ) {
        JsonObject capture = new JsonObject();
        capture.addProperty("schemaVersion", 1);
        capture.addProperty("capturedAt", Instant.now().toString());
        capture.addProperty("eventCanceled", event.isCanceled());
        capture.addProperty("chatType", String.valueOf(event.getType()));
        capture.addProperty("unformatted", unformatted);
        capture.addProperty("formatted", message.getFormattedText());
        capture.add(
            "component",
            new JsonParser().parse(ITextComponent.Serializer.componentToJson(message))
        );
        capture.add("hoverEvents", collectHoverEvents(message));
        return capture;
    }

    private static JsonArray collectHoverEvents(ITextComponent message) {
        JsonArray hoverEvents = new JsonArray();
        Set<String> seen = new HashSet<>();

        for (ITextComponent part : message) {
            HoverEvent hover = part.getStyle().getHoverEvent();
            if (hover == null || hover.getValue() == null) {
                continue;
            }

            ITextComponent value = hover.getValue();
            String valueJson = ITextComponent.Serializer.componentToJson(value);
            String fingerprint = hover.getAction().getCanonicalName() + "\n" + valueJson;
            if (!seen.add(fingerprint)) {
                continue;
            }

            JsonObject item = new JsonObject();
            item.addProperty("sourceText", part.getUnformattedComponentText());
            item.addProperty("action", hover.getAction().getCanonicalName());
            item.addProperty("valueUnformatted", value.getUnformattedText());
            item.addProperty("valueFormatted", value.getFormattedText());
            item.add("valueComponent", new JsonParser().parse(valueJson));
            hoverEvents.add(item);
        }

        return hoverEvents;
    }

    private synchronized void writeCapture(JsonObject capture) throws IOException {
        Files.createDirectories(outputDirectory);

        String compact = COMPACT_GSON.toJson(capture) + System.lineSeparator();
        Files.write(
            capturesFile,
            compact.getBytes(StandardCharsets.UTF_8),
            StandardOpenOption.CREATE,
            StandardOpenOption.APPEND
        );

        String pretty = PRETTY_GSON.toJson(capture) + System.lineSeparator();
        Files.write(
            latestFile,
            pretty.getBytes(StandardCharsets.UTF_8),
            StandardOpenOption.CREATE,
            StandardOpenOption.TRUNCATE_EXISTING
        );
    }
}
