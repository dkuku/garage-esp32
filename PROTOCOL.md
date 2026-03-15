# F-LINX Garage Door Controller - Protocol Documentation

## Overview

The F-LINX garage door controller uses a layered communication architecture:

```
Phone App (F-LINX / Noru)
    |
    | BLE (AES-ECB encrypted, custom Noru protocol)
    | or MQTT via WiFi (mqtt://conn.noru.top:1883)
    |
ESP32-C3 Dongle (Noru "door_hub", firmware 3.0.0, ESP-IDF v5.1.2)
    |
    | UART 115200 8N1 (binary frames, "protov1" protocol)
    |
Gate Motor Controller
```

The Android app (F-LINX) is a **white-label Tuya Smart app** (`com.forcedooriot.smart`).
The original dongle firmware is made by **Noru** and uses a custom protocol stack
(NOT standard Tuya DP protocol) over BLE and MQTT.

### Original Dongle Architecture (from flash dump decompilation)

```
./main/door_hub_main.c         - Entry point, init sequence
./main/door_hub_uart.c         - UART to gate motor controller
./main/door_hub_ble.c          - BLE GATT server (AES-ECB encrypted)
./main/door_hub_mqtt.c         - MQTT client (Noru cloud)
./main/door_hub_wifi.c         - WiFi STA
./main/door_hub_biz_base.c     - Business logic (encode/decode, crypto)
./main/door_hub_biz_dongle.c   - Dongle-specific logic, UART frame parser
./main/door_hub_store.c        - NVS + RingFS persistence
./main/door_hub_ota.c          - OTA updates
./main/door_hub_console.c      - Serial debug console
./main/door_hub_sensor.c       - Door sensor (BLE paired)
```

---

## Layer 1: UART Protocol — "protov1" (ESP32 <-> Gate Motor Controller)

### Physical Parameters
- Baud rate: **115200**
- Data bits: 8, Stop bits: 1, Parity: NONE
- Original dongle pins: TX=GPIO6, RX=GPIO7 (UART1)
- ESPHome replacement pins: TX=GPIO21, RX=GPIO20

### Frame Structure (General)

Both TX and RX frames share a common structure:

```
[START] [LENGTH] [MSG_TYPE] [DATA...] [CRC] [0x0D]
```

| Field | Size | Description |
|-------|------|-------------|
| START | 1 byte | `0x23` for TX (ESP→Motor), `0x40` for RX (Motor→ESP) |
| LENGTH | 1 byte | Total frame length in bytes (including START and footer) |
| MSG_TYPE | 1 byte | Message type identifier (see tables below) |
| DATA | variable | Payload bytes |
| CRC | 1 byte | Checksum (sum of all preceding bytes & 0xFF) |
| FOOTER | 1 byte | Always `0x0D` |

---

### TX Frames: Commands (ESP32 -> Motor Controller)

#### Standard Command (7 bytes)

**Format:** `[0x23] [0x07] [0x41] [CMD] [0x00] [CRC] [0x0D]`

| Byte | Field | Value |
|------|-------|-------|
| 0 | START | `0x23` |
| 1 | LENGTH | `0x07` (7 bytes total) |
| 2 | MSG_TYPE | `0x41` (command) |
| 3 | **CMD** | Command code (see table) |
| 4 | PARAM | `0x00` (unused for basic commands) |
| 5 | **CRC** | `(sum of bytes 0-4) & 0xFF` |
| 6 | FOOTER | `0x0D` |

#### Extended Command (12 bytes)

**Format:** `[0x23] [0x0C] [0x41] [CMD] [DATA x6] [CRC] [0x0D]`

Used for commands with additional parameters (e.g., position target, auto-close config).

#### Command Codes (byte 3)

| Value | Action | Description |
|-------|--------|-------------|
| `0x00` | **OPEN** | Full open |
| `0x01` | **STOP** | Stop movement |
| `0x02` | **CLOSE** | Full close |
| `0x03` | **PARTIAL** | Partial open (ventilation) |
| `0xF0` | **LED ON** | Turn on built-in LED |
| `0xF1` | **LED OFF** | Turn off built-in LED |

#### TX CRC Calculation
```
CRC = (sum of all bytes before CRC position) & 0xFF
```

Example: OPEN command
```
Bytes: 23 07 41 00 00
CRC:   (0x23 + 0x07 + 0x41 + 0x00 + 0x00) & 0xFF = 0x6B
Frame: 23 07 41 00 00 6B 0D
```

---

### RX Frames: Motor Controller -> ESP32

#### RX Message Types

The motor controller sends different message types. All share the same framing:
`[0x40] [LENGTH] [MSG_TYPE] [DATA...] [CRC] [0x0D]`

| MSG_TYPE | Char | Name | Description |
|----------|------|------|-------------|
| `0x49` | `I` | **Status Report** | Periodic status with direction, position, params |
| `0x45` | `E` | **Device Enum** | Device info/registration (26 bytes payload, includes dongle ID) |
| `0x41` | `A` | **Command Ack** | Acknowledges a TX command. Data[0] = echoed command code |
| `0x42` | `B` | **Button Event** | Physical button/trigger. `0xA9`=pair success |
| `0x4A` | `J` | **Join/Pair** | Pairing response. `0xA9`=OK, `0xFF`=reset |
| `0x43` | `C` | **Config** | Configuration data (e.g., auto-close timer) |
| `0x54` | `T` | **Temperature** | Temperature sensor reading |
| `0x56` | `V` | **Voltage** | Voltage/version reading |
| `0x52` | `R` | **Revolution** | Encoder/revolution data (low nibble + high nibble) |
| `0x50` | `P` | **Position Param** | Position-related parameter |

---

#### Status Report (MSG_TYPE = 0x49) — Main status frame

**Format:** `[0x40] [0x11] [0x49] [13 bytes data] [0x0D]` = 17 bytes total

The firmware parses this as 5 reported values (from Ghidra decompilation):
```c
direction  = data[0];                                    // 0=Opening, 1=Stopped, 2=Closing
position   = data[1];                                    // 0-100 (%)
param1     = (data[2] << 8) | data[3];                   // uint16 big-endian (LED-related)
param2     = (data[4] << 8) | data[5];                   // uint16 big-endian (LED-related)
unknown_10 = data[10];                                    // purpose TBD
```

**Full payload structure (14 bytes, offsets 0-13 after header `[0x40][0x11]`):**

| Offset | Name | Description | Known Values |
|--------|------|-------------|--------------|
| 0 | MSG_TYPE | Always `0x49` | `0x49` |
| 1 | **DIRECTION** | Movement direction | `0x00`=Opening, `0x01`=Stopped, `0x02`=Closing |
| 2 | **LED_STATE** | LED on/off | `0xF0`=ON, `0xF1`=OFF |
| 3-4 | **CYCLE_COUNT_1** | Motor cycle counter (uint16 BE) | Increments +1 per open/close cycle |
| 5-6 | **CYCLE_COUNT_2** | Motor cycle counter #2 (= CYCLE_COUNT_1 + 1) | Always CC1 + 1 |
| 7 | **CONTROLLER_ID** | Controller type/hardware ID | Constant `0x74` (116) |
| 8 | **ENCODER_POS** | Motor encoder position (uint8, wrapping) | Overflows 0↔255 during movement |
| 9 | **RESERVED** | Unused | Always `0x00` |
| 10 | **MOTOR_LOAD** | Motor current/load indicator | Higher when opening (~45 avg), lower when closing (~19 avg). Used for obstacle detection |
| 11 | **POSITION** | Door position in % | `0x00`=0% (closed) .. `0x64`=100% (fully open) |
| 12 | **MOVE_FLAG** | Movement status flag | `0x00`=moving, `0x02`=stopped |
| 13 | **CRC** | Checksum | Sum of all preceding bytes & 0xFF |

#### Decoded Example Frames (raw 14-byte payload after header)

```
              MSG DIR LED  CC1   CC2   ID  ENC  R  LOAD POS  MV  CRC
              --- --- ---  ----  ----  --  ---  -- ---- ---  --  ---
Opening  5%:  49  00  F0  02 43  02 44  74  5B  00  1B  05   00  xx
Opening 45%:  49  00  F0  02 43  02 44  74  7F  00  3B  2D   00  xx
Opening 86%:  49  00  F0  02 43  02 44  74  9F  00  22  56   00  xx
Stopped100%:  49  01  F0  02 43  02 44  74  FD  00  21  64   02  xx
Closing 76%:  49  02  F0  02 43  02 44  74  10  00  14  4C   00  xx
Closing 13%:  49  02  F0  02 43  02 44  74  01  00  0A  0D   00  xx
Stopped  0%:  49  01  F0  02 44  02 45  74  A2  00  18  00   02  xx
LED OFF  0%:  49  01  F1  02 9F  02 A4  74  A2  00  18  00   02  xx
```

Key observations from live capture:
- **CYCLE_COUNT** increments by 1 after each complete open/close movement
- **ENCODER_POS** wraps around 0↔255 continuously during movement
- **MOTOR_LOAD** averages ~45 when opening (lifting), ~19 when closing (gravity-assisted)
  - This is likely used by the motor controller for obstacle detection (safety stop)
  - Lower values at end of travel indicate deceleration/braking
- **CONTROLLER_ID** is constant `0x74` for this motor controller model

#### Command Ack (MSG_TYPE = 0x41)

When the motor controller acknowledges a command, it echoes back the command code:
- `data[0]` = original command byte (0x00=open, 0x01=stop, 0x02=close, 0x03=partial)
- Special: values 0xF0/0xF1 are LED ack
- Values 0x00-0x03 also update the current direction state

#### Config (MSG_TYPE = 0x43)

Auto-close configuration:
- `data[0]` = auto-close timer value (minutes? needs verification)

#### Device Enum (MSG_TYPE = 0x45)

26-byte payload containing device identification:
- Bytes 9-16: dongle ID (8 bytes, formatted as hex string `%02x` x 8)
- Used for initial device registration/pairing

### Field Details (confirmed via live UART capture)

- **Bytes 3-6 (CYCLE_COUNT_1, CYCLE_COUNT_2)**: Motor cycle counters (uint16 big-endian)
  - CC2 is always CC1 + 1
  - Both increment by 1 after each complete open or close movement
  - Example: CC1=578, CC2=579 → after next cycle → CC1=579, CC2=580
  - Earlier observations of LED-correlated changes were coincidental

- **Byte 7 (CONTROLLER_ID)**: Constant `0x74` (116) — hardware/model identifier
  - Does not change with position, direction, or LED state

- **Byte 8 (ENCODER_POS)**: Raw motor encoder position (uint8, wrapping)
  - Continuously increments/decrements during movement, wraps at 0/255
  - Stable value when stopped (e.g., `0xA2` at 0%, `0xFD` at 100%)

- **Byte 10 (MOTOR_LOAD)**: Motor current/torque indicator
  - Opening (lifting): avg ~45 (range 27-68) — higher load against gravity
  - Closing (lowering): avg ~19 (range 10-22) — gravity assists
  - Decreases near end of travel — motor decelerating/braking
  - Used by controller for **obstacle detection** (safety stop if load exceeds threshold)

- **Byte 12 (MOVE_FLAG)**: `0x00` during movement, `0x02` when stopped

---

## Layer 2: Noru Cloud Protocol (Phone <-> ESP32 Dongle)

### Architecture

The original dongle is NOT a standard Tuya device. It runs Noru's own firmware with:

**BLE:**
- Custom GATT server with two channels: **biz** (business logic) and **log**
- **AES-ECB encryption** (NOT AES-CBC as in standard Tuya)
- Token-based authentication (`req_auth` + `token` field)
- Frame format: create → encode → ECB encrypt → BLE notify
- Decoding: ECB decrypt → CRC check → seq check → time check → parse

**MQTT:**
- Broker: `mqtt://conn.noru.top:1883`
- Username/password: `noru` / `Noru3Dq9Wx7Z`
- BLE device name format: `Noru_%02X%02X%02X%02X%02X%02X` (from MAC)

### MQTT Topic Structure

```
/thing/{hub_id}/{dongle_id}/service/up       # Commands sent upstream
/thing/{hub_id}/{dongle_id}/service/down     # Commands received
/thing/{hub_id}/{dongle_id}/attr/up          # Attribute reports (status)
/thing/{hub_id}/{dongle_id}/event/up         # Events
/thing/{hub_id}/{dongle_id}/log              # Log upload
```

### MQTT/BLE Commands (from firmware strings)

| Command | Direction | Description |
|---------|-----------|-------------|
| `req_door_ctrl` | Request | Door control (open/close/stop) |
| `req_get_param` | Request | Read parameters |
| `req_set_param` | Request | Set parameters |
| `req_auto_close` | Request | Configure auto-close |
| `req_study` | Request | Start limit learning |
| `req_auth` | Request | BLE authentication |
| `req_upgrade` | Request | OTA firmware upgrade |
| `req_log_switch` | Request | Toggle logging |
| `req_wifi_scan` | Request | Scan WiFi networks |
| `req_wifi_connect` | Request | Connect to WiFi |

| Response | Direction | Description |
|----------|-----------|-------------|
| `dev_rsp_door_ctrl` | Response | Door control result |
| `dev_rsp_get_param` | Response | Parameter values |
| `dev_rsp_set_param` | Response | Set confirmation |
| `rsp_upgrade` | Response | OTA status |
| `study_report` | Response | Learning result |
| `pair_status` | Response | Pairing status |
| `attr_report` | Response | Attribute update |
| `upgrade_status` | Response | Upgrade progress |
| `log_upload` | Response | Log data |

### Legacy Tuya Layer (from APK decompilation)

The F-LINX APK is built on the Tuya SDK but the actual device communication goes through
Noru's custom protocol. The Tuya BLE/DP layer in the APK may be vestigial or used only
for initial provisioning. The relevant protocol details are in the Noru layer above.

---

## Layer 3: ESPHome Integration (ESP32 replacement)

The original Noru dongle can be replaced with a generic ESP32-C3 running ESPHome,
communicating directly with the gate motor controller via UART.

### Home Assistant Entities

| Entity | Type | Description |
|--------|------|-------------|
| `cover.garage` | Cover | Main garage door control (open/close/stop + position) |
| `sensor.door_status` | Sensor | Door position in % |
| `binary_sensor.door_moving` | Binary Sensor | True when door is in motion |
| `light.led` | Light | Built-in LED control |
| `button.open` | Button | Direct open command |
| `button.stop` | Button | Direct stop command |
| `button.close` | Button | Direct close command |
| `button.partial_open` | Button | Ventilation/partial open |
| `text_sensor.operation` | Text Sensor | Current direction (Opening/Stopped/Closing) |
| `text_sensor.uart_last_reply` | Text Sensor | Last raw UART hex response |

### Cover Position Mapping
```
Position 0%   = Fully closed
Position 100% = Fully open
```
The `cover.garage` entity reads position from UART and exposes it as 0.0-1.0 to Home Assistant.

---

## Files Reference

| Path | Description |
|------|-------------|
| `sterownik-bramy-garaz.yaml` | ESPHome configuration (replacement firmware) |
| `fx-link-dongle-backup.bin` | Original Noru dongle flash dump (4MB, ESP32-C3) |
| `ghidra_import/` | Ghidra project files and decompiled code |
| `ghidra_import/decompiled/` | Decompiled C functions from Noru firmware |
| `decompiled/` | Full jadx decompilation of F-LINX APK |
| `decompiled/sources/com/forcedooriot/smart/` | App-specific code |
| `decompiled/sources/com/tuya/sdk/ble/core/` | Tuya BLE protocol stack (in APK) |
| `F-LINX_1.0.0_APKPure.apk` | Original APK |
