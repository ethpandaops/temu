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
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Optional;
import java.util.Queue;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import tech.pegasys.teku.ethereum.events.GossipMessageAcceptedEvent;
import tech.pegasys.teku.infrastructure.ssz.SszData;
import tech.pegasys.teku.infrastructure.unsigned.UInt64;
import tech.pegasys.teku.spec.datastructures.blobs.DataColumnSidecar;
import tech.pegasys.teku.spec.datastructures.blobs.versions.deneb.BlobSidecar;
import tech.pegasys.teku.spec.datastructures.blocks.SignedBeaconBlock;
import tech.pegasys.teku.spec.datastructures.operations.Attestation;
import tech.pegasys.teku.spec.datastructures.operations.SignedAggregateAndProof;

/**
 * Core xatu sidecar functionality. Manages event batching and native library communication.
 */
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

  @SuppressWarnings("unused")
  private String networkName = "unknown";

  /**
   * Initialize the xatu sidecar with configuration from file and genesis time from Teku.
   *
   * @param configPath path to YAML/JSON configuration file
   * @param genesisTime the genesis time from Teku's chain data (overrides config value)
   * @return true if initialization succeeded
   */
  public boolean initialize(final String configPath, final UInt64 genesisTime) {
    if (initialized.getAndSet(true)) {
      LOG.warn("Xatu sidecar already initialized");
      return true;
    }

    try {
      String configContent = Files.readString(Paths.get(configPath));

      // Always inject Teku's genesis time (overrides config value)
      if (genesisTime != null && !genesisTime.isZero()) {
        configContent = injectGenesisTime(configContent, genesisTime.longValue());
        LOG.info("Injected genesis_time={} into xatu config", genesisTime);
      }

      byte[] configBytes = (configContent + "\0").getBytes(StandardCharsets.UTF_8);

      int result = XatuNativeLibrary.INSTANCE.Init(configBytes);
      if (result != 0) {
        LOG.error("Failed to initialize xatu native library, error code: {}", result);
        initialized.set(false);
        return false;
      }

      // Start the batch flush scheduler
      @SuppressWarnings("unused")
      var ignored = scheduler.scheduleAtFixedRate(
          this::flushBatch, FLUSH_INTERVAL_MS, FLUSH_INTERVAL_MS, TimeUnit.MILLISECONDS);

      LOG.info("Xatu sidecar initialized successfully with config: {}", configPath);
      return true;
    } catch (Exception e) {
      LOG.error("Failed to initialize xatu sidecar", e);
      initialized.set(false);
      return false;
    }
  }

  /**
   * Inject genesis time into YAML config content, overriding the existing value.
   */
  private String injectGenesisTime(final String yamlContent, final long genesisTime) {
    // Replace existing genesis_time value in the YAML
    String pattern = "(genesis_time:\\s*)\\d+";
    String replacement = "$1" + genesisTime;
    return yamlContent.replaceAll(pattern, replacement);
  }

  /**
   * Set the network name for event metadata.
   *
   * @param networkName the network name (e.g., "mainnet", "holesky")
   */
  public void setNetworkName(final String networkName) {
    this.networkName = networkName;
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
    String messageId = event.getMessageId().toHexString();
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
      eventNode.put("attestation_data_root", agg.getData().hashTreeRoot().toHexString());
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
      eventNode.put("attestation_data_root", attestation.getData().hashTreeRoot().toHexString());
      eventNode.put("topic", topic);
      eventNode.put("source_root", attestation.getData().getSource().getRoot().toHexString());
      eventNode.put("target_root", attestation.getData().getTarget().getRoot().toHexString());
      if (!attestation.isSingleAttestation()) {
        eventNode.put("aggregation_bits", attestation.getAggregationBits().sszSerialize().toHexString());
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
      eventNode.put("proposer_index", blobSidecar.getSignedBeaconBlockHeader().getMessage().getProposerIndex().longValue());
      eventNode.put("blob_index", blobSidecar.getIndex().longValue());
      eventNode.put("message_size", messageSize);
      eventNode.put("peer_id", peerId);
      eventNode.put("message_id", messageId);
      eventNode.put("topic", topic);
      eventNode.put("block_root", blobSidecar.getBlockRoot().toHexString());
      eventNode.put("parent_root", blobSidecar.getSignedBeaconBlockHeader().getMessage().getParentRoot().toHexString());
      eventNode.put("state_root", blobSidecar.getSignedBeaconBlockHeader().getMessage().getStateRoot().toHexString());
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
      dataColumnSidecar.getMaybeSignedBlockHeader().ifPresent(header -> {
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

    LOG.info("Xatu sidecar shutdown complete");
  }
}
