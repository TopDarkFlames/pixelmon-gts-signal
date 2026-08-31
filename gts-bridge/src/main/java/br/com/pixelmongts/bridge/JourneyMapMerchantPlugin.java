package br.com.pixelmongts.bridge;

import journeymap.client.api.ClientPlugin;
import journeymap.client.api.IClientAPI;
import journeymap.client.api.IClientPlugin;
import journeymap.client.api.event.ClientEvent;

@ClientPlugin
public final class JourneyMapMerchantPlugin implements IClientPlugin {
    @Override
    public void initialize(IClientAPI api) {
        MerchantWaypointManager.initialize(api);
    }

    @Override
    public String getModId() {
        return GtsBridge.MOD_ID;
    }

    @Override
    public void onEvent(ClientEvent event) {
        // No JourneyMap events are required; chat events drive waypoint updates.
    }
}
