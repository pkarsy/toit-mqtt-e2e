# UNDER CONSTRUCTION
![Status](https://img.shields.io/badge/status-under%20construction-red)

## mqtt-e2e
Zero-config, broker-agnostic, end-to-end encrypted communication using MQTT instead of TCP sockets.

## Security in a nutshell
- Every payload is encrypted with AES-128-GCM **before** publish.
- Each message carries a **monotonically increasing nonce + UTC timestamp**; duplicates are rejected.
- **fixed-length padding** (default is 50 bytes) hides the real size.
- No TLS, no account, no broker password, no certificates – the broker sees only random bytes.

## You may want to use it :
- To avoid maintaining server accounts and certificates. The only thing the 2 nodes need, to be able to communicate effectivelly and securelly, is the common 16-byte key.
- To easily bypass firewalls, NAT and double NAT
- As a terminal replacemnet. You can send commands to the IOT module and the module replies via the same channel.
- For rapid IoT prototypes that must use **unknown or untrusted** public brokers.
- For IOT units that connect / disconnect frequently or change networks, so direct TLS connections are not practical.

## You may want to avoid it when :
- You have account to a **TLS-enabled** broker, and you trust the broker.
- You need **Broker-level access control** (topic ACLs)
- You need to hide **traffic-timing** – padding alone is not enough.
- You want to protect the ESP32 modules from direct internet exposure.

## Threat model
| Protected against | NOT protected against |
|--------------------|----------------------|
| Passive eavesdropper on MQTT topic | Traffic analysis / timing correlation |
| Replay of old messages | Device compromise (key extraction) |
| Message forgery (no key = no write) | Broker availability (DoS) |

## Install
```bash
jag pkg install github.com/pkarsy/toit-mqtt-e2e
```

## Examples

Full working programs are in the `examples/` folder:

Before running the programs put a **unique** randomly generated key in
`shared.toit`. Inside the file there are instructions on how to generate the key.

- `iot-example.toit` – IOT side. Run it with

  `jag run -d "yourIOT" iot-example.toit -O2`
  You need to have `jag monitor` running to see what's happening.
  Also works with `-d host`
- `controller-example.toit` – command side. Run it with

  `jag run -d host controller-example.toit`

## Time window
Every encrypted message has the time of creation as cleartext at the start of the packet. It cannot be forged as it is used as part of the IV. Given that (to be able to use the library) the modules are internet connected, they can also have their RTC well synchronized. The `ntp-time` helper function (in `main`) can conveniently do this. For this reason the allowed time window outside of which the message is rejected is relativelly small (10sec but can be afdjusted)
The receiver keeps the last N timestamps(At the moment 1). When 2 messages arrive one after another. And someone send the first packet again trying to perform a replay attack, the message will be rejected despite being in the 10 sec window.


## Padding
Messages shorter than `--pad-size` are padded with random bytes. Longer messages are sent as-is.  Choose `pad-size` slightly larger than your largest expected message if you want to hide the size of the messages. **Changing pad-size does NOT break compatibility** – receivers auto-detect.


## Key distribution
- Usually the nodes share the same source tree so the key is naturally hardcoded in each node. This mechanism does not scale for more than a few devices. In theese cases every IOT(or a few IOTs) must have its own key and the controller can distinguise them using the topic.
- The library does **not** implement key exchange.
You must provision the 16-byte key out-of-band (BLE, UART, etc). Another idea is to use ed25519 to create a shared secret(the key can be derived from this), but again this is not implemented.


## Performance
On a 160 MHz ESP32:
- Encrypt + publish 100 bytes ~2ms
- RAM overhead per Session  TODO

## TODO
Limit the incoming packet size to protect from large packets. The mqtt brokers even the free, allow for packets that easily fill the limited ESP32 memory.

## License
MIT – contributions welcome.

## Disclaimer
Any information leakage, cannot be blamed to the author see the MIT licence.