<img src="../Logo.png" alt="Logo" width="400">

# olo_intf_can

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_intf_can.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_intf_can.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_intf_can.json?cacheSeconds=0)

VHDL Source: [olo_intf_can](../../src/intf/vhdl/olo_intf_can.vhd), bit timing helper
[olo_intf_pkg_can](../../src/intf/vhdl/olo_intf_pkg_can.vhd)

## Description

### Overview

This entity implements a CAN 2.0B protocol controller: standard (11-bit) and extended (29-bit) data and remote frames,
arbitration, error detection and signalling, fault confinement and bit timing with synchronisation. It connects to a
CAN transceiver through _Can_Tx_ and _Can_Rx_ ('1' is the recessive level).

User logic sends and receives whole frames: one beat on _Tx\_\*_ is one frame to send, one pulse on _Rx_Valid_ is
one received frame. The controller retransmits a frame automatically after an error or a lost arbitration until it is
sent, aborted or the node goes bus off.

The _Can_Rx_ input is synchronized internally (_SyncStages_g_, _SyncTmr_g_).

The protocol follows the Bosch CAN Specification 2.0 (1991), part B. The references in this document name its
sections.

### Conformance

| Part B section | Content | Implemented |
| --- | --- | --- |
| 3.1, 3.2.1, 3.2.2 | Standard and extended data and remote frames | Transmit and receive |
| 3.2.3 | Error frames (active and passive error flag, error delimiter) | Yes |
| 3.2.4 | Overload frames | Reaction to overload conditions 2 and 3; condition 1 (a receiver that needs a delay) is never generated |
| 3.2.5 | Interframe space, suspend transmission, start of frame in the third intermission bit | Yes |
| 3.3 | Conformance with regard to frame formats | Full extended format support |
| 4 | Message filtering | Not in the controller: every valid frame is output, see [Filtering](#filtering) |
| 5 | Message validation | Yes |
| 6 | Bit stuffing | Yes |
| 7 | Error detection (bit, stuff, CRC, form, acknowledgment error) and signalling | Yes |
| 8 | Fault confinement, rules 1 to 12 with both exceptions of rule 3 | Yes |
| 9, 10 | Bit timing, hard synchronization, resynchronization | Yes, programmable at runtime |
| 2 | Sleep mode and wake-up | No |

CAN FD, time-triggered CAN and higher layers are not part of this entity.

## Generics

| Name          | Type     | Default | Description |
| :------------ | :------- | ------- | :---------- |
| SyncStages_g  | positive | 2       | Number of synchronization stages for _Can_Rx_. <br />Range: 2 ... 4 |
| SyncTmr_g     | boolean  | false   | Implement the synchronizer as three chains with a majority voter, see [clock-crossing principles](../base/clock_crossing_principles.md#triplicated-synchronizers) |
| AutoRecover_g | boolean  | true    | **true**: a bus-off node recovers after 128 occurrences of 11 consecutive recessive bits (section 8 rule 12) <br />**false**: the recovery (with the same 128 x 11 recessive bits) starts only after a pulse on _Ctrl_Recover_ |

## Interfaces

### Control

| Name         | In/Out | Length | Default | Description |
| :----------- | :----- | :----- | ------- | :---------- |
| Clk          | in     | 1      | -       | Clock |
| Rst          | in     | 1      | -       | Reset input (high-active, synchronous to _Clk_) |
| Ctrl_Recover | in     | 1      | '0'     | Pulse: start the bus-off recovery (only used for _AutoRecover_g_ = false) |

### Configuration

The configuration must be static while _Cfg_Enable_ = '1'. See [Bit Timing](#bit-timing) for the values.

| Name           | In/Out | Length | Default | Description |
| :------------- | :----- | :----- | ------- | :---------- |
| Cfg_Enable     | in     | 1      | '1'     | '0': the controller does not take part in the bus (_Can_Tx_ recessive). After '1' it integrates (11 recessive bits) before it sends or receives. The error counters and the bus-off state are kept. |
| Cfg_Prescaler  | in     | 10     | -       | Clock cycles per time quantum <br />Range: 1 ... 1023 (0 is treated as 1) |
| Cfg_Tseg1      | in     | 5      | -       | PROP_SEG + PHASE_SEG1 in time quanta <br />Range: 2 ... 31 |
| Cfg_Tseg2      | in     | 4      | -       | PHASE_SEG2 in time quanta <br />Range: 2 ... 15 |
| Cfg_Sjw        | in     | 3      | -       | Resynchronization jump width in time quanta <br />Range: 1 ... min(4, PHASE_SEG1, _Cfg_Tseg2_) |
| Cfg_ListenOnly | in     | 1      | '0'     | '1': the controller receives but never drives the bus: no acknowledge, no error or overload flags, no transmission; the error counters do not change |
| Cfg_Loopback   | in     | 1      | '0'     | '1': the transmitted bits are looped back internally, _Can_Tx_ stays recessive. The controller acknowledges its own frames and outputs them on _Rx\_\*_ (self test). |

### Transmit Frame

| Name       | In/Out | Length | Default | Description |
| :--------- | :----- | :----- | ------- | :---------- |
| Tx_Valid   | in     | 1      | '0'     | AXI4-Stream handshaking signal for the frame |
| Tx_Ready   | out    | 1      | N/A     | AXI4-Stream handshaking signal for the frame: '1' while no frame is pending |
| Tx_Id      | in     | 29     | 0       | Identifier. Standard frames: bits 28 ... 18 (bits 17 ... 0 are ignored) |
| Tx_Ide     | in     | 1      | '0'     | '1': extended frame (29-bit identifier) |
| Tx_Rtr     | in     | 1      | '0'     | '1': remote frame (no data field) |
| Tx_Dlc     | in     | 4      | 0       | Data length code; 9 ... 15 send 8 bytes |
| Tx_Data    | in     | 64     | 0       | Data bytes, byte 0 (sent first) in bits 63 ... 56 |
| Tx_Abort   | in     | 1      | '0'     | Pulse: drop the pending frame. A frame that is on the bus is completed: _Tx_Done_ on success, otherwise it is dropped instead of retransmitted. |
| Tx_Done    | out    | 1      | N/A     | Pulse: the frame was sent (no error up to the end of the end of frame field) |
| Tx_Aborted | out    | 1      | N/A     | Pulse: the frame was dropped after _Tx_Abort_ |
| Tx_ArbLost | out    | 1      | N/A     | Pulse: the frame lost the arbitration (it is retransmitted later) |

### Receive Frame

There is no _Ready_ signal (a CAN receiver cannot delay the bus): the user must accept every frame. Use a FIFO (e.g.
[olo_base_fifo_sync](../base/olo_base_fifo_sync.md) or [olo_ft_fifo_sync](../ft/olo_ft_fifo_sync.md)) if the frames
cannot be processed at once.

| Name     | In/Out | Length | Default | Description |
| :------- | :----- | :----- | ------- | :---------- |
| Rx_Valid | out    | 1      | N/A     | Pulse: a valid frame was received (no error up to the last but one bit of the end of frame field) |
| Rx_Id    | out    | 29     | N/A     | Identifier (standard frames: bits 28 ... 18, bits 17 ... 0 are 0) |
| Rx_Ide   | out    | 1      | N/A     | '1': extended frame |
| Rx_Rtr   | out    | 1      | N/A     | '1': remote frame |
| Rx_Dlc   | out    | 4      | N/A     | Data length code as received |
| Rx_Data  | out    | 64     | N/A     | Data bytes, byte 0 in bits 63 ... 56; bytes beyond the data length are 0 |

The _Rx\_\*_ signals are valid together with _Rx_Valid_ only.

### Status and Error Events

| Name         | In/Out | Length | Default | Description |
| :----------- | :----- | :----- | ------- | :---------- |
| Stat_Tec     | out    | 9      | N/A     | Transmit error count |
| Stat_Rec     | out    | 8      | N/A     | Receive error count (saturates at 255) |
| Stat_State   | out    | 2      | N/A     | "00": error active, "01": error passive, "11": bus off |
| Stat_BusIdle | out    | 1      | N/A     | '1' while the bus is idle |
| Err_Bit      | out    | 1      | N/A     | Pulse: bit error detected |
| Err_Stuff    | out    | 1      | N/A     | Pulse: stuff error detected |
| Err_Crc      | out    | 1      | N/A     | Pulse: CRC error detected (at the start of the error flag after the ACK delimiter) |
| Err_Form     | out    | 1      | N/A     | Pulse: form error detected |
| Err_Ack      | out    | 1      | N/A     | Pulse: acknowledgment error detected |

### CAN Interface

| Name   | In/Out | Length | Default | Description |
| :----- | :----- | :----- | ------- | :---------- |
| Can_Tx | out    | 1      | N/A     | To the transceiver ('1' = recessive) |
| Can_Rx | in     | 1      | '1'     | From the transceiver ('1' = recessive) |

## Detailed Description

### Bit Timing

A bit consists of time quanta of _Cfg_Prescaler_ clock cycles: one quantum SYNC_SEG, _Cfg_Tseg1_ quanta
PROP_SEG + PHASE_SEG1 and _Cfg_Tseg2_ quanta PHASE_SEG2 (section 10). The bus is sampled at the end of PHASE_SEG1, a
new bit is driven at the start of SYNC_SEG.

```text
bit rate     = clock frequency / (Cfg_Prescaler * (1 + Cfg_Tseg1 + Cfg_Tseg2))
sample point = (1 + Cfg_Tseg1) / (1 + Cfg_Tseg1 + Cfg_Tseg2)
```

PROP_SEG must cover twice the delay of the bus line, the transceiver and the input synchronizer
(_SyncStages_g_ + 1 clock cycles). The controller needs one clock cycle after the sample point to compute the next
bit, so the information processing time is below one time quantum; _Cfg_Tseg2_ = 2 is the smallest value the Bosch
rules allow (PHASE_SEG2 not shorter than an information processing time of 2 quanta).

Synchronization (section 10):

- A hard synchronization restarts the bit at a recessive-to-dominant edge while the bus is idle (start of frame), also
  during integration, suspend transmission and bus off.
- Within a frame, recessive-to-dominant edges resynchronize the bit: PHASE_SEG1 is lengthened or PHASE_SEG2 shortened
  by the phase error, at most _Cfg_Sjw_ quanta. Only one synchronization happens between two sample points, only after
  a recessive sample, and a node that sends a dominant bit ignores edges with a positive phase error.

The package _olo_intf_pkg_can_ computes a configuration for a clock, a bit rate and a sample point:

```vhdl
library olo;
    use olo.olo_intf_pkg_can.all;
    use olo.olo_base_pkg_math.all;

constant Bt_c : CanBitTiming_t := canBitTiming(ClkFreq => 50.0e6, BitRate => 500.0e3, SamplePoint => 0.75);

i_can : entity olo.olo_intf_can
    port map (
        Clk           => Clk,
        Rst           => Rst,
        Cfg_Prescaler => toUslv(Bt_c.Prescaler, 10),
        Cfg_Tseg1     => toUslv(Bt_c.Tseg1, 5),
        Cfg_Tseg2     => toUslv(Bt_c.Tseg2, 4),
        Cfg_Sjw       => toUslv(Bt_c.Sjw, 3),
        ...
    );
```

_canBitTiming_ chooses 8 to 25 time quanta per bit with the smallest bit rate error (more quanta at equal error),
places the sample point as close to _SamplePoint_ as possible within the Bosch ranges (PROP_SEG and PHASE_SEG1 1 to 8
quanta each, PHASE_SEG2 2 to 8 quanta) and sets SJW to min(4, PHASE_SEG1, PHASE_SEG2). It stops with a failure if no
setting reaches the bit rate within _MaxRateError_ (default 0.1 %). Tying the ports to these constants gives a
controller with a fixed bit rate.

PHASE_SEG2 is programmable independently of PHASE_SEG1. Bosch 2.0 defines PHASE_SEG2 as the maximum of PHASE_SEG1 and
the information processing time; later sample points (for example 87.5 %) need the independent setting.

The oscillator tolerance of a setting follows from the usual conditions (bit time in quanta):

```text
df <= SJW / (20 * bit time)
df <= min(PHASE_SEG1, PHASE_SEG2) / (2 * (13 * bit time - PHASE_SEG2))
```

The 1.58 % of section 9 need for example 10 quanta with PHASE_SEG2 = 4 and SJW = 4.

### Transmission

A frame is taken with _Tx_Valid_ while _Tx_Ready_ = '1' and stays pending until _Tx_Done_ or _Tx_Aborted_. The
controller starts it at the first bit of bus idle, or in the third bit of the intermission when another node starts a
frame there (section 3.2.5: the controller then continues with the identifier). After a lost arbitration
(_Tx_ArbLost_) the controller receives the other frame and retries afterwards; after an error it retransmits after
the error frame and the interframe space.

An error passive transmitter waits 8 more bits after the intermission (suspend transmission) before it starts a new
frame.

### Reception

Every valid frame is output, also remote frames and frames with a data length code above 8 (_Rx_Dlc_ as received,
8 data bytes). The controller acknowledges every frame with a correct CRC (not in listen-only mode). Frames sent by
the controller itself are not output, except in loopback mode.

#### Filtering

The controller has no acceptance filter (section 4 makes it optional). Because _Rx\_\*_ has no back pressure, a
filter on the receive frames is equivalent and can be any logic, for example a mask and a code:

```vhdl
Accept <= Rx_Valid when (Rx_Id and Mask_c) = (Code_c and Mask_c) and Rx_Ide = Ide_c else '0';
```

### Error Handling and Fault Confinement

Detected errors are signalled with an error flag (section 7.2): an active error flag (6 dominant bits) when the node
is error active, a passive error flag (6 recessive bits) when it is error passive. CRC errors are flagged after the
ACK delimiter, all others in the bit after the error. Every error pulses one of the _Err\_\*_ outputs.

The transmit and receive error counts follow the rules of section 8, including:

- exception 1 of rule 3: an error passive transmitter without acknowledge does not increase its count unless it sees a
  dominant bit during its passive error flag (so a single node on a bus becomes error passive, but not bus off);
- exception 2 of rule 3: a stuff error on a recessive stuff bit of the arbitration field that is monitored dominant;
- rule 8: a successful reception decrements the receive count; a count above 127 is set to 119.

The node is error passive for a count of 128 or more and bus off for a transmit count of 256 or more. A bus-off node
keeps _Can_Tx_ recessive, keeps a pending frame and recovers (both counts 0, error active) after 128 occurrences of
11 consecutive recessive bits. With _AutoRecover_g_ = false, the counting starts only after a pulse on _Ctrl_Recover_,
so the user decides when a node rejoins the bus (for example when redundant buses are managed by a higher layer).

### Modes

- **Listen-only** (_Cfg_ListenOnly_ = '1'): monitoring without influence on the bus. Errors are detected and pulsed,
  but the counters do not change and no flag is sent. A pending frame is not started.
- **Loopback** (_Cfg_Loopback_ = '1'): the controller receives its own bits and acknowledges its own frames;
  _Can_Tx_ stays recessive, the bus is ignored.
- **Disabled** (_Cfg_Enable_ = '0'): _Can_Tx_ recessive, no participation. After enabling, the controller integrates
  again (11 recessive bits); the error counters and the bus-off state are kept (disabling does not bypass the bus-off
  recovery).

### Protection

The controller has no memories; its registers are protected by the TMR of the synthesis tool if required. Every
state machine returns to integration from any illegal state.
