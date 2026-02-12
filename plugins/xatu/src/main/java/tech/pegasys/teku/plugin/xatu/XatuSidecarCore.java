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

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.fasterxml.jackson.dataformat.yaml.YAMLMapper;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.Optional;
import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import tech.pegasys.teku.ethereum.events.GossipMessageAcceptedEvent;
import tech.pegasys.teku.infrastructure.ssz.SszData;
import tech.pegasys.teku.infrastructure.unsigned.UInt64;
import tech.pegasys.teku.infrastructure.version.VersionProvider;
import tech.pegasys.teku.spec.datastructures.blobs.DataColumnSidecar;
import tech.pegasys.teku.spec.datastructures.blobs.versions.deneb.BlobSidecar;
import tech.pegasys.teku.spec.datastructures.blocks.SignedBeaconBlock;
import tech.pegasys.teku.spec.datastructures.operations.Attestation;
import tech.pegasys.teku.spec.datastructures.operations.SignedAggregateAndProof;

/** Core xatu sidecar functionality. Manages event batching and native library communication. */
public class XatuSidecarCore {
  private static final Logger LOG = LogManager.getLogger();
  private static final ObjectMapper MAPPER = new ObjectMapper();
  private static final int BATCH_SIZE = 100;
  private static final long FLUSH_INTERVAL_MS = 1000;
  private static final long SLOTS_PER_EPOCH = 32;

  private final Queue<ObjectNode> eventQueue = new ConcurrentLinkedQueue<>();
  private final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();
  private final AtomicBoolean initialized = new AtomicBoolean(false);
  private final AtomicBoolean shutdown = new AtomicBoolean(false);

  // Transport peer tracking (moved from GossipHandler to reduce patch footprint)
  private final AtomicLong transportPeerPresentCount = new AtomicLong(0);
  private final AtomicLong transportPeerMissingCount = new AtomicLong(0);

  /**
   * Initialize the xatu sidecar by building a full runtime config from user config and chain data.
   *
   * <p>Parses the user config YAML, enriches it with runtime data (genesis time, network info, spec
   * constants, client version), and passes the full config to the native library.
   *
   * @param configPath path to user YAML configuration file
   * @param genesisTime the genesis time from Teku's chain data
   * @param networkName the network name from Teku (e.g., "mainnet", "holesky")
   * @param networkId the deposit network ID from the spec
   * @param slotsPerEpoch the slots per epoch from the spec
   * @param secondsPerSlot the seconds per slot from the spec
   * @return true if initialization succeeded
   */
  public boolean initialize(
      final String configPath,
      final long genesisTime,
      final String networkName,
      final long networkId,
      final int slotsPerEpoch,
      final int secondsPerSlot) {
    if (initialized.getAndSet(true)) {
      LOG.warn("Xatu sidecar already initialized");
      return true;
    }

    try {
      // Parse user config
      YAMLMapper yamlMapper = new YAMLMapper();
      JsonNode userConfig = yamlMapper.readTree(new File(configPath));

      // Check enabled field — if false or missing, skip init
      JsonNode enabledNode = userConfig.get("enabled");
      if (enabledNode == null || !enabledNode.asBoolean(false)) {
        LOG.info("Xatu sidecar disabled in config");
        initialized.set(false);
        return false;
      }

      // Build full runtime config matching xatu-sidecar format
      ObjectNode fullConfig = yamlMapper.createObjectNode();

      // Log level from env or default
      String logLevel = System.getenv("XATU_LOG_LEVEL");
      fullConfig.put("log_level", logLevel != null ? logLevel : "info");

      // Processor section
      ObjectNode processor = fullConfig.putObject("processor");

      // Name from user config or default
      JsonNode nameNode = userConfig.get("name");
      processor.put("name", nameNode != null ? nameNode.asText() : "teku");

      // Outputs from user config
      JsonNode outputsNode = userConfig.get("outputs");
      if (outputsNode != null) {
        processor.set("outputs", outputsNode);
      }

      // Ethereum section
      ObjectNode ethereum = processor.putObject("ethereum");
      ethereum.put("implementation", "teku");
      ethereum.put("genesis_time", genesisTime);
      ethereum.put("seconds_per_slot", secondsPerSlot);
      ethereum.put("slots_per_epoch", slotsPerEpoch);

      // Network — use override from user config if present
      ObjectNode network = ethereum.putObject("network");
      String resolvedNetworkName = networkName;
      JsonNode ethNode = userConfig.get("ethereum");
      if (ethNode != null) {
        JsonNode overrideNode = ethNode.get("overrideNetworkName");
        if (overrideNode != null && !overrideNode.asText().isEmpty()) {
          resolvedNetworkName = overrideNode.asText();
        }
      }
      network.put("name", resolvedNetworkName);
      network.put("id", networkId);

      // Client section
      ObjectNode client = processor.putObject("client");
      client.put("name", "teku");
      client.put("version", VersionProvider.IMPLEMENTATION_VERSION);

      // Optional ntpServer from user config
      JsonNode ntpNode = userConfig.get("ntpServer");
      if (ntpNode != null) {
        processor.put("ntpServer", ntpNode.asText());
      }

      // Serialize to YAML and pass to native library
      String configYaml = yamlMapper.writeValueAsString(fullConfig);
      byte[] configBytes = (configYaml + "\0").getBytes(StandardCharsets.UTF_8);

      LOG.info(
          "Initializing xatu sidecar: network={}, genesis_time={}, "
              + "slots_per_epoch={}, seconds_per_slot={}, network_id={}, version={}",
          resolvedNetworkName,
          genesisTime,
          slotsPerEpoch,
          secondsPerSlot,
          networkId,
          VersionProvider.IMPLEMENTATION_VERSION);

      int result = XatuNativeLibrary.INSTANCE.Init(configBytes);
      if (result != 0) {
        LOG.error("Failed to initialize xatu native library, error code: {}", result);
        initialized.set(false);
        return false;
      }

      // Start the batch flush scheduler
      @SuppressWarnings("unused")
      var ignored =
          scheduler.scheduleAtFixedRate(
              this::flushBatch, FLUSH_INTERVAL_MS, FLUSH_INTERVAL_MS, TimeUnit.MILLISECONDS);

      LOG.info("Xatu sidecar initialized successfully");
      return true;
    } catch (Exception e) {
      LOG.error("Failed to initialize xatu sidecar", e);
      initialized.set(false);
      return false;
    }
  }

  /**
   * Process a gossip message accepted event.
   *
   * @param event the gossip message event
   */
  public void onGossipMessageAccepted(final GossipMessageAcceptedEvent event) {
    if (!initialized.get() || shutdown.get()) {
      return;
    }

    // Track transport peer presence for monitoring
    if (event.getTransportPeerId().isPresent()) {
      transportPeerPresentCount.incrementAndGet();
    } else {
      transportPeerMissingCount.incrementAndGet();
    }

    try {
      Optional<ObjectNode> eventJson = convertToXatuEvent(event);
      eventJson.ifPresent(eventQueue::add);

      // Flush if batch size reached
      if (eventQueue.size() >= BATCH_SIZE) {
        flushBatch();
      }
    } catch (Exception e) {
      LOG.debug("Failed to process gossip event", e);
    }
  }

  private Optional<ObjectNode> convertToXatuEvent(final GossipMessageAcceptedEvent event) {
    SszData message = event.getMessage();
    String topic = event.getTopic();
    long timestampMs = event.getArrivalTimestamp().orElse(UInt64.ZERO).longValue();
    String peerId = event.getTransportPeerId().orElse("");
    String messageId = event.getMessageId().toUnprefixedHexString();
    int messageSize = event.getMessageSize();

    // Type-specific conversion - flat format matching xatu-sidecar Raw* structs
    if (message instanceof SignedBeaconBlock block) {
      ObjectNode eventNode = MAPPER.createObjectNode();
      eventNode.put("event_type", "BEACON_BLOCK");
      long slot = block.getSlot().longValue();
      eventNode.put("timestamp_ms", timestampMs);
      eventNode.put("slot", slot);
      eventNode.put("epoch", slot / SLOTS_PER_EPOCH);
      eventNode.put("proposer_index", block.getMessage().getProposerIndex().longValue());
      eventNode.put("message_size", messageSize);
      eventNode.put("peer_id", peerId);
      eventNode.put("message_id", messageId);
      eventNode.put("topic", topic);
      eventNode.put("block_root", block.getRoot().toHexString());
      return Optional.of(eventNode);

    } else if (message instanceof SignedAggregateAndProof signedAgg) {
      ObjectNode eventNode = MAPPER.createObjectNode();
      eventNode.put("event_type", "AGGREGATE_AND_PROOF");
      Attestation agg = signedAgg.getMessage().getAggregate();
      long slot = agg.getData().getSlot().longValue();
      eventNode.put("slot", slot);
      eventNode.put("epoch", slot / SLOTS_PER_EPOCH);
      eventNode.put("aggregator_index", signedAgg.getMessage().getIndex().longValue());
      eventNode.put("timestamp_ms", timestampMs);
      eventNode.put("source_epoch", agg.getData().getSource().getEpoch().longValue());
      eventNode.put("target_epoch", agg.getData().getTarget().getEpoch().longValue());
      eventNode.put("committee_index", agg.getFirstCommitteeIndex().longValue());
      eventNode.put("message_size", messageSize);
      eventNode.put("peer_id", peerId);
      eventNode.put("message_id", messageId);
      eventNode.put("attestation_data_root", agg.getData().getBeaconBlockRoot().toHexString());
      eventNode.put("topic", topic);
      eventNode.put("source_root", agg.getData().getSource().getRoot().toHexString());
      eventNode.put("target_root", agg.getData().getTarget().getRoot().toHexString());
      eventNode.put("aggregation_bits", agg.getAggregationBits().sszSerialize().toHexString());
      eventNode.put("signature", agg.getAggregateSignature().toSSZBytes().toHexString());
      return Optional.of(eventNode);

    } else if (message instanceof Attestation attestation) {
      ObjectNode eventNode = MAPPER.createObjectNode();
      eventNode.put("event_type", "ATTESTATION");
      long slot = attestation.getData().getSlot().longValue();
      eventNode.put("slot", slot);
      eventNode.put("epoch", slot / SLOTS_PER_EPOCH);
      eventNode.put("subnet_id", extractSubnetId(topic));
      eventNode.put("timestamp_ms", timestampMs);
      eventNode.put("source_epoch", attestation.getData().getSource().getEpoch().longValue());
      eventNode.put("target_epoch", attestation.getData().getTarget().getEpoch().longValue());
      eventNode.put("committee_index", attestation.getFirstCommitteeIndex().longValue());
      if (attestation.isSingleAttestation()) {
        eventNode.put("attester_index", attestation.getValidatorIndexRequired().longValue());
      } else {
        eventNode.put("attester_index", 0L);
      }
      eventNode.put("message_size", messageSize);
      eventNode.put("should_process", true);
      eventNode.put("peer_id", peerId);
      eventNode.put("message_id", messageId);
      eventNode.put("attestation_data_root", attestation.getData().getBeaconBlockRoot().toHexString());
      eventNode.put("topic", topic);
      eventNode.put("source_root", attestation.getData().getSource().getRoot().toHexString());
      eventNode.put("target_root", attestation.getData().getTarget().getRoot().toHexString());
      if (!attestation.isSingleAttestation()) {
        eventNode.put(
            "aggregation_bits", attestation.getAggregationBits().sszSerialize().toHexString());
      } else {
        eventNode.put("aggregation_bits", "");
      }
      eventNode.put("signature", attestation.getAggregateSignature().toSSZBytes().toHexString());
      return Optional.of(eventNode);

    } else if (message instanceof BlobSidecar blobSidecar) {
      ObjectNode eventNode = MAPPER.createObjectNode();
      eventNode.put("event_type", "BLOB_SIDECAR");
      long slot = blobSidecar.getSlot().longValue();
      eventNode.put("timestamp_ms", timestampMs);
      eventNode.put("slot", slot);
      eventNode.put("epoch", slot / SLOTS_PER_EPOCH);
      eventNode.put(
          "proposer_index",
          blobSidecar.getSignedBeaconBlockHeader().getMessage().getProposerIndex().longValue());
      eventNode.put("blob_index", blobSidecar.getIndex().longValue());
      eventNode.put("message_size", messageSize);
      eventNode.put("peer_id", peerId);
      eventNode.put("message_id", messageId);
      eventNode.put("topic", topic);
      eventNode.put("block_root", blobSidecar.getBlockRoot().toHexString());
      eventNode.put(
          "parent_root",
          blobSidecar.getSignedBeaconBlockHeader().getMessage().getParentRoot().toHexString());
      eventNode.put(
          "state_root",
          blobSidecar.getSignedBeaconBlockHeader().getMessage().getStateRoot().toHexString());
      return Optional.of(eventNode);

    } else if (message instanceof DataColumnSidecar dataColumnSidecar) {
      ObjectNode eventNode = MAPPER.createObjectNode();
      eventNode.put("event_type", "DATA_COLUMN_SIDECAR");
      long slot = dataColumnSidecar.getSlot().longValue();
      eventNode.put("timestamp_ms", timestampMs);
      eventNode.put("slot", slot);
      eventNode.put("epoch", slot / SLOTS_PER_EPOCH);
      eventNode.put("column_index", dataColumnSidecar.getIndex().longValue());
      eventNode.put("kzg_commitments_count", dataColumnSidecar.getKzgCommitments().size());
      eventNode.put("message_size", messageSize);
      eventNode.put("peer_id", peerId);
      eventNode.put("message_id", messageId);
      eventNode.put("topic", topic);
      eventNode.put("block_root", dataColumnSidecar.getBeaconBlockRoot().toHexString());
      // Get optional header fields if available
      dataColumnSidecar
          .getMaybeSignedBlockHeader()
          .ifPresent(
              header -> {
                eventNode.put("proposer_index", header.getMessage().getProposerIndex().longValue());
                eventNode.put("parent_root", header.getMessage().getParentRoot().toHexString());
                eventNode.put("state_root", header.getMessage().getStateRoot().toHexString());
              });
      return Optional.of(eventNode);
    }

    // Unknown type - skip (e.g. SyncCommitteeMessage, SignedContributionAndProof)
    return Optional.empty();
  }

  private long extractSubnetId(final String topic) {
    // Topic format: /eth2/<fork_digest>/beacon_attestation_<subnet_id>/ssz_snappy
    try {
      int idx = topic.indexOf("beacon_attestation_");
      if (idx >= 0) {
        int start = idx + "beacon_attestation_".length();
        int end = topic.indexOf('/', start);
        if (end < 0) {
          end = topic.length();
        }
        return Long.parseLong(topic.substring(start, end));
      }
    } catch (NumberFormatException e) {
      // Ignore parsing errors
    }
    return 0L;
  }

  private synchronized void flushBatch() {
    if (eventQueue.isEmpty() || !initialized.get()) {
      return;
    }

    ArrayNode batch = MAPPER.createArrayNode();
    ObjectNode event;
    int count = 0;

    while ((event = eventQueue.poll()) != null && count < BATCH_SIZE) {
      batch.add(event);
      count++;
    }

    if (batch.isEmpty()) {
      return;
    }

    try {
      String json = MAPPER.writeValueAsString(batch);
      byte[] jsonBytes = (json + "\0").getBytes(StandardCharsets.UTF_8);

      int result = XatuNativeLibrary.INSTANCE.SendEventBatch(jsonBytes);
      if (result != 0) {
        LOG.warn("Failed to send event batch, error code: {}", result);
      }
    } catch (JsonProcessingException e) {
      LOG.warn("Failed to serialize event batch", e);
    }
  }

  /** Shutdown the xatu sidecar. */
  public void shutdown() {
    if (shutdown.getAndSet(true)) {
      return;
    }

    LOG.info("Shutting down xatu sidecar");

    // Stop scheduler
    scheduler.shutdown();
    try {
      if (!scheduler.awaitTermination(5, TimeUnit.SECONDS)) {
        scheduler.shutdownNow();
      }
    } catch (InterruptedException e) {
      scheduler.shutdownNow();
      Thread.currentThread().interrupt();
    }

    // Flush remaining events
    flushBatch();

    // Shutdown native library
    if (initialized.get()) {
      XatuNativeLibrary.INSTANCE.Shutdown();
    }

    LOG.info(
        "Xatu sidecar shutdown complete. Transport peer stats: present={}, missing={}",
        transportPeerPresentCount.get(),
        transportPeerMissingCount.get());
  }

  /** Get the count of messages where transport peer was present. */
  public long getTransportPeerPresentCount() {
    return transportPeerPresentCount.get();
  }

  /** Get the count of messages where transport peer was missing. */
  public long getTransportPeerMissingCount() {
    return transportPeerMissingCount.get();
  }
}
