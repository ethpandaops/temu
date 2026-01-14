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

import com.sun.jna.Library;
import com.sun.jna.Native;

/**
 * JNA interface to the xatu-sidecar native library (libxatu.so).
 *
 * <p>The library exports three functions:
 *
 * <ul>
 *   <li>Init - Initialize with JSON configuration
 *   <li>SendEventBatch - Send a batch of events as JSON
 *   <li>Shutdown - Clean shutdown
 * </ul>
 */
@SuppressWarnings("JavaCase") // JNA requires exact C function names
public interface XatuNativeLibrary extends Library {

  /** Singleton instance of the native library. */
  XatuNativeLibrary INSTANCE = Native.load("xatu", XatuNativeLibrary.class);

  /**
   * Initialize the xatu sidecar with configuration.
   *
   * @param configJSON null-terminated JSON configuration string
   * @return 0 on success, non-zero on error
   */
  int Init(byte[] configJSON);

  /**
   * Send a batch of events to xatu.
   *
   * @param events null-terminated JSON array of events
   * @return 0 on success, non-zero on error
   */
  int SendEventBatch(byte[] events);

  /** Shutdown the xatu sidecar. */
  void Shutdown();
}
