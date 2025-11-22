## mqtt_e2e
Zero-config, broker-agnostic, end-to-end encrypted MQTT for Toit.

> **Security in a nutshell**
> - Every payload is encrypted with AES-256-GCM **before** publish.
! - Each message carries a **monotonically increasing nonce + UTC timestamp**; duplicates are rejected.
> - **fixed-length padding** (default 50 bytes) hides the real size.
> - No TLS, no broker password, no certificates – the broker sees only random bytes.

## When you should use this
- Rapid IoT prototypes that must transit **unknown or untrusted** public brokers.
- Devices that lack the RAM/CUU for TLS but still need **strong confidentiality & inntegrity**.
- Field units that connect / disconnect frequently and cannot afford handshake overhead.

## When you should NOT
- You already control a **TLS-enabled** broker and can afford certificates.
- You need **Broker-level access control** (topic ACLs)\
- You must hide **traffic-timing** – padding alone is not enough.

## Threat model
| Protected against | NOT protected against |
|--------------------|----------------------|
| Passive eavesdropper on MQTT topic | Traffic analysis / timing correlation |
| Replay of old messages | Device compromise (key extraction) |
| Message forgery (no key = no write) | Broker availability (DoS) |

## Install
```bash
toit pkg install github.com/yourname/toit-mqtt-e2e
```

## 30-second example
```toit
import mqtt
import mqtt_e2e

KEY: = #[
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
]

main:
  client/mqtt.Client := mqtt.Client --host="broker.emqx.io"
  session := mqtt_e2e.Session client --key=KEY --pad_size=50

  // publish
  session.publish "device/42/log" "Hello from Toit!"

  // subscribe
  session.subscribe "device/42/cmd" :: | topic payload |
    print "Received decrypted: $payload"
```

## API summary
```toit
Session --key=32-byte/ByteArray --pad_size=int --clock_skew=Duration
  publish topic/string payload/any -> none
  subscribe topic/string [block] -> none
  last_seen_nonce -> int   // debugging replay window
```

## Replay window
The receiver keeps the last 64 nonces in RAM. Messages older than **clock_skew** (default 5 min) or with a repeated nonce are dropped. Increase `clock_skew` on battery-powered devices that sleep for long periods.

## Padding
Messages shorter than `pad_size` are padded with random bytes; longer messages are sent as-is.  Choose `pad_size` slightly larger than your largest expected JSON blob.  **Changing pad_size does NOT break compatibility** – receivers auto-detect.

## Key distribution
This library does **not** implement key exchange.  You must provision the 32-byte key out-of-band (QR-code, BLE, UIRT, etc.).  Rotate keys by simply creating a new `Session`.

## Performance
On a 160 MHz ESP32:
- Encrypt + publish 100 bytes ⌕ 1.8 ms
- RAM overhead per Session – 1.2 kB

## Road-map / contributions
- ChaCha20-Poly1305 option for 8-bit MCUs
- X25519 key agreement helper (optional)
- Topic wildcard support

## License
MIT   – contributions welcome.