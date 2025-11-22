# ![Status](https://img.shields.io/badge/status-under%20construction-red)

## mqtt-e2e
Zero-config, broker-agnostic, end-to-end encrypted MQTT for Toit.

> **Security in a nutshell**
> - Every payload is encrypted with AES-128-GCM **before** publish.
! - Each message carries a **monotonically increasing nonce + UTC timestamp**; duplicates are rejected.
> - **fixed-length padding** (default is 50 bytes) hides the real size.
> - No TLS, no broker password, no certificates – the broker sees only random bytes.

## When you should use this
- The most important of all, no need to maintain server accounts and certificates. No need to be on the same network to communicate with your IOT devices. The only thing 2 nodes need, to be able to communicate effectivelly and securelly, is the common 16-byte key.
- Especially effective as a replacement of a terminal. You can send commands to the IOT module and the module replies via the same channel.
- Rapid IoT prototypes that must use **unknown or untrusted** public brokers.
- Avoid TLS overhead, certificates maintenance etc.  but still need **strong confidentiality & integrity**. The module introduces its own overhead however.
- IOT units that connect / disconnect frequently so direct TLS connections are not practical.

## When you should NOT
- You already control a **TLS-enabled** broker and can afford certificates. You have to trust the broker however.
- You need **Broker-level access control** (topic ACLs)
- You must hide **traffic-timing** – padding alone is not enough. Again the timing is known to the broker, so you have to trust the broker. Of course this is the smallest problem as the broker can read the messages.

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

## Examples

Full working programs are in the `examples/` folder:

- `examples/iot-example.toit` – device side
- `examples/controller-example.toit` – command side

before running the programs put a **unique** randomly generated key in
- `examples/shared.toit`


Run locally:

```bash
cd examples

jag run -d ESP32(your device) iot-example.toit -O2

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
- The idea is all the nodes share the same source tree so the key is naturally hardcoded in each node. This is the main mechanism for shared secret distribution.
Of course this is not always the case.
- The library does **not** implement key exchange.
You must provision the 16-byte key out-of-band (QR-code, BLE, UART, etc.).
- Another idea is to use ed25519 to create a shared secret but again is
not implemented. This method of course works only for point-to-point communication,
for example for controlling a single device.
- Generally speaking the shared secret method cannot scale well for a large number of devices.
For such cases, public key crypto has advantages(but even then there are problems), but also huge complexity penalty, and as I have not use cases for this, not implemented.

## Performance
On a 160 MHz ESP32:
- Encrypt + publish 100 bytes ⌕ 1.8 ms
- RAM overhead per Session – 1.2 kB

## License
MIT   – contributions welcome.