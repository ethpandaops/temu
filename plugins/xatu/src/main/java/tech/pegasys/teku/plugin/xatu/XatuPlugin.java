/*
 * Copyright Consensys Software Inc., 2025
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
 * an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 */

package tech.pegasys.teku.plugin.xatu;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import tech.pegasys.teku.ethereum.events.GossipMessageAcceptedChannel;
import tech.pegasys.teku.ethereum.events.GossipMessageAcceptedEvent;
import tech.pegasys.teku.infrastructure.events.EventChannels;
import tech.pegasys.teku.infrastructure.unsigned.UInt64;

/**
 * Xatu plugin for Teku. Subscribes to gossip message events and forwards them to xatu-sidecar.
 */
public class XatuPlugin implements GossipMessageAcceptedChannel {
  private static final Logger LOG = LogManager.getLogger();

  private final XatuSidecarCore core = new XatuSidecarCore();
  private final String configPath;

  /**
   * Create a new XatuPlugin.
   *
   * @param configPath path to the xatu configuration file
   */
  public XatuPlugin(final String configPath) {
    this.configPath = configPath;
  }

  /**
   * Initialize the plugin with the event channels and genesis time.
   *
   * @param eventChannels the event channels to subscribe to
   * @param genesisTime the genesis time from Teku (injected into xatu config)
   */
  public void initialize(final EventChannels eventChannels, final UInt64 genesisTime) {
    if (!core.initialize(configPath, genesisTime)) {
      LOG.error("Failed to initialize xatu plugin");
      return;
    }

    // Subscribe to gossip message events
    eventChannels.subscribe(GossipMessageAcceptedChannel.class, this);
    LOG.info("Xatu plugin initialized with genesis_time={}", genesisTime);

    // Register shutdown hook
    Runtime.getRuntime().addShutdownHook(new Thread(core::shutdown));
  }

  /**
   * Set the network name for event metadata.
   *
   * @param networkName the network name
   */
  public void setNetworkName(final String networkName) {
    core.setNetworkName(networkName);
  }

  @Override
  public void onGossipMessageAccepted(final GossipMessageAcceptedEvent event) {
    core.onGossipMessageAccepted(event);
  }
}
