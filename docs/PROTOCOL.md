# Worx Landroid cloud protocol: what MowerBar uses

These notes cover what MowerBar implements for wired Landroid mowers (cloud protocol 0). They come from observing the app's own traffic with the user's own account and from public community projects, mainly [pyworxcloud](https://github.com/MTrab/pyworxcloud) and [ioBroker.worx](https://github.com/iobroker-community-adapters/ioBroker.worx). Worx does not document this API and may change it.

## Sign-in

- OAuth 2 authorization code with PKCE (S256) at `https://id.worx.com/oauth/authorize`. Tokens come from `https://id.worx.com/oauth/token`.
- MowerBar uses the public client identifier and the redirect URI of the official mobile app, like the community libraries do. The redirect `https://app.worxlandroid.com/login` is intercepted inside the web view and never loaded.
- Access tokens are JWTs. MowerBar refreshes them 5 minutes before expiry with `grant_type=refresh_token`.

## REST (read only)

All requests go to `https://api.worxlandroid.com` with `Authorization: Bearer <token>`.

| Path | Use |
|---|---|
| `/api/v2/product-items?status=1&gps_status=1&all=1` | Mowers of the account. The response includes `serial_number`, `mqtt_endpoint`, `mqtt_topics.command_in` / `command_out`, `protocol`, `capabilities`, `time_zone`, `online` and `last_status.payload` (last `cfg` + `dat`). |
| `/api/v2/products` | Catalogue, used to show the model code. |
| `/api/v2/product-items/{serial}/activity-log` | Activity log: `timestamp` plus `payload` with `cfg` and `dat`. |

## MQTT

- MQTT 5 over TLS on port 443, to the `mqtt_endpoint` of the mower. The username carries the JWT for the AWS custom authorizer; see `MQTTWire.username`.
- Subscribe to `command_out` and publish to `command_in`. Always use the topics returned by the API; never build them.
- MowerBar publishes with QoS 1, without retain or DUP, and never keeps an offline queue.

### Message envelope (protocol 0)

```json
{"cmd": 0, "sn": "<serial>", "dt": "dd/MM/yyyy", "tm": "HH:mm:ss", "id": 1024}
```

`dt` and `tm` are in the mower's time zone. `id` (1024…65534) comes back as `cfg.id` in the mower's answer, which is how MowerBar knows a command or setting was received.

### Commands

| `cmd` | Meaning | In MowerBar |
|---:|---|---|
| 0 | Status request; also the envelope for settings | Yes |
| 1 | Start mowing | Yes |
| 2 | Stop / pause | Yes |
| 3 | Go home | No (9 is used instead) |
| 4 | Follow the boundary wire | No |
| 5 / 6 | Anti-theft lock / unlock | No |
| 7 | Restart according to pyworxcloud; meaning uncertain | No |
| 8 | Pause over the wire | No |
| 9 | Safe go home, blades stopped (capability `safe_go_home`) | Yes |

**Resume after an error.** For errors the mower declares resumable remotely (`dat.er = 2`), the official app sends `cmd` 1 or 9 with the current `"ls"` and `"le"` copied into the message. Wired mowers do not send `er`, so the official app never offers this for them. MowerBar's experimental option sends the same format. Its effect on wired firmware is not validated.

### Settings (always `cmd: 0`)

| Key | Range | Notes |
|---|---|---|
| `tq` | −50…50 | Wheel torque in %. |
| `rd` | 0…1440 | Delay after rain, in minutes. |
| `sc` | object | Schedule. `d` and `dd` hold 7 entries each (index 0 = Sunday): `["HH:MM", minutes, edgeCut 0/1]`. MowerBar sends back `d`, `dd`, `m`, `p` and `distm` exactly as received, and changes only the edge-cut flag. It never sends `ots` (the one-time mow) and never attaches a go-home command to a schedule write. |

### Telemetry (`dat`)

| Key | Meaning |
|---|---|
| `ls` | State. 0 needs attention, 1 at the base, 2 starting, 3 leaving the base, 4 following the wire, 5 searching for the base, 6 searching for the wire, 7 mowing, 8–10 recovery, 11 self-test, 12 manual driving, 30 going home, 31 zone training, 32 cutting edges, 33 searching for a zone, 34 paused. |
| `le` | Error. 0 none, 1 trapped, 2 lifted, 3 wire missing, 4 outside the mowing area, 5 rain delay, 6 cover open, 7 close the cover to go home, 8 blade motor, 9 wheel motor, 10 trapped too long, 11 upside down, 12 battery low, 14 charging error, 15 not enough sensor data, 122 stopped manually. |
| `bt.p`, `bt.c` | Battery %, charging (1). |

## Remote driving

The official app drives mowers with a joystick only over Bluetooth LE, and only for devices that declare the capability `bluetooth_remote_driving`. Its MQTT transport refuses driving requests. MowerBar does not implement driving.
