package br.com.pixelmongts.bridge;

import java.util.Arrays;
import java.util.Collection;
import java.util.SortedSet;
import java.util.TreeSet;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import journeymap.client.api.IClientAPI;
import journeymap.client.api.display.DisplayType;
import journeymap.client.api.display.Waypoint;
import journeymap.client.waypoint.WaypointStore;
import net.minecraft.client.Minecraft;
import net.minecraft.util.math.BlockPos;
import net.minecraftforge.common.DimensionManager;

final class MerchantWaypointManager {
    private static final Logger LOGGER = LogManager.getLogger(GtsBridge.MOD_ID);
    private static final String WAYPOINT_ID = "traveling_merchant_current";
    private static final int WAYPOINT_COLOR = 0x2EE7DF;

    private static IClientAPI api;
    private static MerchantAnnouncement pendingAnnouncement;

    private MerchantWaypointManager() {
    }

    static synchronized void initialize(IClientAPI clientApi) {
        api = clientApi;
        LOGGER.info("JourneyMap API initialized for traveling merchant waypoints");
        if (pendingAnnouncement != null) {
            updateWaypoint(pendingAnnouncement);
            pendingAnnouncement = null;
        }
    }

    static synchronized void updateWaypoint(MerchantAnnouncement announcement) {
        if (api == null) {
            pendingAnnouncement = announcement;
            LOGGER.warn("JourneyMap API is not ready; merchant waypoint queued");
            return;
        }

        if (!api.playerAccepts(GtsBridge.MOD_ID, DisplayType.Waypoint)) {
            LOGGER.warn("JourneyMap waypoint display is disabled for {}", GtsBridge.MOD_ID);
            return;
        }

        Minecraft minecraft = Minecraft.getMinecraft();
        int dimension = minecraft.player == null ? 0 : minecraft.player.dimension;
        int[] displayDimensions = getDisplayDimensions(dimension);
        String name = "Mercador - " + announcement.getLocation();
        Waypoint waypoint = new Waypoint(
            GtsBridge.MOD_ID,
            WAYPOINT_ID,
            name,
            dimension,
            new BlockPos(announcement.getX(), announcement.getY(), announcement.getZ())
        );
        waypoint.setPersistent(true);
        waypoint.setEditable(true);
        waypoint.setColor(WAYPOINT_COLOR);
        waypoint.setDisplayDimensions(displayDimensions);

        try {
            if (api.exists(waypoint)) {
                api.remove(waypoint);
            }
            api.show(waypoint);
            LOGGER.info(
                "JourneyMap waypoint updated: {} at {} {} {}; visible in dimensions {}",
                name,
                announcement.getX(),
                announcement.getY(),
                announcement.getZ(),
                Arrays.toString(displayDimensions)
            );
        } catch (Exception exception) {
            LOGGER.error("Could not create the JourneyMap merchant waypoint", exception);
        }
    }

    private static int[] getDisplayDimensions(int currentDimension) {
        SortedSet<Integer> dimensions = new TreeSet<>();
        dimensions.add(-1);
        dimensions.add(0);
        dimensions.add(1);
        dimensions.add(currentDimension);

        try {
            addDimensions(dimensions, WaypointStore.INSTANCE.getLoadedDimensions());
        } catch (RuntimeException exception) {
            LOGGER.warn("Could not read JourneyMap's loaded dimensions", exception);
        }

        try {
            addDimensions(dimensions, Arrays.asList(DimensionManager.getStaticDimensionIDs()));
            addDimensions(dimensions, Arrays.asList(DimensionManager.getIDs()));
        } catch (RuntimeException exception) {
            LOGGER.warn("Could not read Forge's registered dimensions", exception);
        }

        int[] result = new int[dimensions.size()];
        int index = 0;
        for (Integer dimension : dimensions) {
            result[index++] = dimension;
        }
        return result;
    }

    private static void addDimensions(SortedSet<Integer> destination, Collection<Integer> source) {
        if (source == null) {
            return;
        }
        for (Integer dimension : source) {
            if (dimension != null) {
                destination.add(dimension);
            }
        }
    }
}
