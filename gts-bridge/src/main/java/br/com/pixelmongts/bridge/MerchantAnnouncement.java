package br.com.pixelmongts.bridge;

import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class MerchantAnnouncement {
    private static final Pattern MESSAGE = Pattern.compile(
        "\\bO\\s+mercador\\s+chegou\\s+em\\s+(.+?)\\s+nas?\\s+coordenadas?\\s*[:=-]?\\s*"
            + "(-?\\d+)\\s*[,;/ ]+\\s*(-?\\d+)\\s*[,;/ ]+\\s*(-?\\d+)\\s*!?",
        Pattern.CASE_INSENSITIVE | Pattern.UNICODE_CASE
    );

    private final String location;
    private final int x;
    private final int y;
    private final int z;

    private MerchantAnnouncement(String location, int x, int y, int z) {
        this.location = location;
        this.x = x;
        this.y = y;
        this.z = z;
    }

    public static Optional<MerchantAnnouncement> parse(String message) {
        Matcher matcher = MESSAGE.matcher(message == null ? "" : message);
        if (!matcher.find()) {
            return Optional.empty();
        }

        try {
            String location = matcher.group(1).replaceAll("\\s+", " ").trim();
            if (location.isEmpty()) {
                return Optional.empty();
            }
            return Optional.of(new MerchantAnnouncement(
                location,
                Integer.parseInt(matcher.group(2)),
                Integer.parseInt(matcher.group(3)),
                Integer.parseInt(matcher.group(4))
            ));
        } catch (NumberFormatException ignored) {
            return Optional.empty();
        }
    }

    public String getLocation() {
        return location;
    }

    public int getX() {
        return x;
    }

    public int getY() {
        return y;
    }

    public int getZ() {
        return z;
    }
}
