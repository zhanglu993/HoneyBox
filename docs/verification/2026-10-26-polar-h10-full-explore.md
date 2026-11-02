# Polar H10 full GATT explore

- Device: `Polar H10 790A8026` / `EE:6A:57:F3:9E:00`
- Host: Linux BlueZ (`hci0`)
- When: 2026-10-26 11:07 Asia/Shanghai
- Counts: **8 services**, **28 characteristics**, **11 descriptors**
- Device Information read OK; Battery **100%**; PMD Control Point readable
- User Data reads were interrupted by link drop (device went away mid-explore); table still lists all UD characteristics discovered

## ECG takeaway

Raw ECG: **PMD** service `fb005c80-02e7-f387-1cad-8acd2d8df0c8` → Control Point `fb005c81` + Data notify `fb005c82`.
Heart Rate `0000180d` / `00002a37` is BPM (+RR), not ECG samples.

## Service overview

| Service UUID | Alias | Characteristics |
|---|---|---:|
| `00001801-0000-1000-8000-00805f9b34fb` | Generic Attribute | 1 |
| `0000180d-0000-1000-8000-00805f9b34fb` | Heart Rate | 2 |
| `0000181c-0000-1000-8000-00805f9b34fb` | User Data | 10 |
| `0000180a-0000-1000-8000-00805f9b34fb` | Device Information | 7 |
| `0000180f-0000-1000-8000-00805f9b34fb` | Battery | 1 |
| `6217ff4b-fb31-1140-ad5a-a45545d7ecf3` | Polar vendor service | 2 |
| `fb005c80-02e7-f387-1cad-8acd2d8df0c8` | PMD (ECG/ACC stream) | 2 |
| `0000feee-0000-1000-8000-00805f9b34fb` | Polar Electro Oy | 3 |

## `00001801-0000-1000-8000-00805f9b34fb` — Generic Attribute

### `00002a05-0000-1000-8000-00805f9b34fb` — Service Changed

- Flags: `indicate`
- Read: _(notify/indicate/write-only, unread, or link dropped)_
- Descriptor `00002902-0000-1000-8000-00805f9b34fb`

## `0000180d-0000-1000-8000-00805f9b34fb` — Heart Rate

### `00002a37-0000-1000-8000-00805f9b34fb` — Heart Rate Measurement

- Flags: `notify`
- Read: _(notify/indicate/write-only, unread, or link dropped)_
- Descriptor `00002902-0000-1000-8000-00805f9b34fb`

### `00002a38-0000-1000-8000-00805f9b34fb` — Body Sensor Location

- Flags: `read`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`

## `0000181c-0000-1000-8000-00805f9b34fb` — User Data

### `00002a99-0000-1000-8000-00805f9b34fb` — Database Change Increment

- Flags: `read, write`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`

### `00002a9a-0000-1000-8000-00805f9b34fb` — User Index

- Flags: `read`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`

### `00002a9f-0000-1000-8000-00805f9b34fb` — User Control Point

- Flags: `write, indicate`
- Read: _(notify/indicate/write-only, unread, or link dropped)_
- Descriptor `00002902-0000-1000-8000-00805f9b34fb`

### `00002a8a-0000-1000-8000-00805f9b34fb` — First Name

- Flags: `read, write, extended-properties, reliable-write`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`
- Descriptor `00002900-0000-1000-8000-00805f9b34fb`

### `00002a90-0000-1000-8000-00805f9b34fb` — Last Name

- Flags: `read, write, extended-properties, reliable-write`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`
- Descriptor `00002900-0000-1000-8000-00805f9b34fb`

### `00002a80-0000-1000-8000-00805f9b34fb` — Age

- Flags: `read, write`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`

### `00002a8c-0000-1000-8000-00805f9b34fb` — Gender

- Flags: `read, write`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`

### `00002a98-0000-1000-8000-00805f9b34fb` — Weight

- Flags: `read, write`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`

### `00002a8e-0000-1000-8000-00805f9b34fb` — Height

- Flags: `read, write`
- Read error: `DBusException: org.bluez.Error.Failed: Not connected`

### `00002aa2-0000-1000-8000-00805f9b34fb` — Language

- Flags: `read, write`
- Read error: `DBusException: org.freedesktop.DBus.Error.NoReply: Did not receive a reply. Possible causes include: the remote application did not send a reply, the message bus security policy blocked the reply, the reply timeout expired, or the network connection was broken.`

## `0000180a-0000-1000-8000-00805f9b34fb` — Device Information

### `00002a29-0000-1000-8000-00805f9b34fb` — Manufacturer Name

- Flags: `read`
- Read: `50 6f 6c 61 72 20 45 6c 65 63 74 72 6f 20 4f 79 00` → **Polar Electro Oy**

### `00002a24-0000-1000-8000-00805f9b34fb` — Model Number

- Flags: `read`
- Read: `48 31 30 00` → **H10**

### `00002a25-0000-1000-8000-00805f9b34fb` — Serial Number

- Flags: `read`
- Read: `37 39 30 41 38 30 32 36 00` → **790A8026**

### `00002a27-0000-1000-8000-00805f9b34fb` — Hardware Revision

- Flags: `read`
- Read: `30 30 37 36 30 36 39 30 2e 30 33 00` → **00760690.03**

### `00002a26-0000-1000-8000-00805f9b34fb` — Firmware Revision

- Flags: `read`
- Read: `35 2e 30 2e 30 00` → **5.0.0**

### `00002a28-0000-1000-8000-00805f9b34fb` — Software Revision

- Flags: `read`
- Read: `33 2e 31 2e 31 00` → **3.1.1**

### `00002a23-0000-1000-8000-00805f9b34fb` — System ID

- Flags: `read`
- Read: `80 0a 79 fe ff 1a 9e a0`

## `0000180f-0000-1000-8000-00805f9b34fb` — Battery

### `00002a19-0000-1000-8000-00805f9b34fb` — Battery Level

- Flags: `read, notify`
- Read: `64` → **100%**
- Descriptor `00002902-0000-1000-8000-00805f9b34fb` read=`01 00` CCCD=0x0001 (notify=True, indicate=False)

## `6217ff4b-fb31-1140-ad5a-a45545d7ecf3` — Polar vendor service

### `6217ff4c-c8ec-b1fb-1380-3ad986708e2d` — Polar vendor char

- Flags: `read`
- Read: `bf 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00`

### `6217ff4d-91bb-91d0-7e2a-7cd3bda8a1f3` — Polar vendor char

- Flags: `write-without-response, indicate`
- Read: _(notify/indicate/write-only, unread, or link dropped)_
- Descriptor `00002902-0000-1000-8000-00805f9b34fb` read=`00 00` CCCD=0x0000 (notify=False, indicate=False)

## `fb005c80-02e7-f387-1cad-8acd2d8df0c8` — PMD (ECG/ACC stream)

### `fb005c81-02e7-f387-1cad-8acd2d8df0c8` — PMD Control Point

- Flags: `read, write, indicate`
- Read: `0f 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00`
- Descriptor `00002902-0000-1000-8000-00805f9b34fb` read=`00 00` CCCD=0x0000 (notify=False, indicate=False)

### `fb005c82-02e7-f387-1cad-8acd2d8df0c8` — PMD Data

- Flags: `notify`
- Read: _(notify/indicate/write-only, unread, or link dropped)_
- Descriptor `00002902-0000-1000-8000-00805f9b34fb` read=`00 00` CCCD=0x0000 (notify=False, indicate=False)

## `0000feee-0000-1000-8000-00805f9b34fb` — Polar Electro Oy

### `fb005c51-02e7-f387-1cad-8acd2d8df0c8` — Polar vendor char

- Flags: `write-without-response, write, notify`
- Read: _(notify/indicate/write-only, unread, or link dropped)_
- Descriptor `00002902-0000-1000-8000-00805f9b34fb` read=`00 00` CCCD=0x0000 (notify=False, indicate=False)

### `fb005c52-02e7-f387-1cad-8acd2d8df0c8` — Polar vendor char

- Flags: `notify`
- Read: _(notify/indicate/write-only, unread, or link dropped)_
- Descriptor `00002902-0000-1000-8000-00805f9b34fb` read=`00 00` CCCD=0x0000 (notify=False, indicate=False)

### `fb005c53-02e7-f387-1cad-8acd2d8df0c8` — Polar vendor char

- Flags: `write-without-response, write`
- Read: _(notify/indicate/write-only, unread, or link dropped)_
