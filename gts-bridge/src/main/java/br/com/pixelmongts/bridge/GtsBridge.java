package br.com.pixelmongts.bridge;

import java.nio.file.Path;

import org.apache.logging.log4j.Logger;

import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.common.event.FMLPreInitializationEvent;

@Mod(
    modid = GtsBridge.MOD_ID,
    name = GtsBridge.NAME,
    version = GtsBridge.VERSION,
    clientSideOnly = true,
    acceptableRemoteVersions = "*"
)
public final class GtsBridge {
    public static final String MOD_ID = "gtsbridge";
    public static final String NAME = "GTS Bridge";
    public static final String VERSION = "0.1.0";

    @Mod.EventHandler
    public void preInit(FMLPreInitializationEvent event) {
        Logger logger = event.getModLog();
        Path gameDirectory = event.getModConfigurationDirectory().toPath().getParent();
        Path outputDirectory = gameDirectory.resolve("gts-bridge");

        MinecraftForge.EVENT_BUS.register(new GtsChatCapture(outputDirectory, logger));
        logger.info("GTS Bridge active. Output directory: {}", outputDirectory);
    }
}
