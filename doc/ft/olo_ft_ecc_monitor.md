<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_ecc_monitor

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_ecc_monitor.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_ecc_monitor.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_ecc_monitor.json?cacheSeconds=0)

VHDL Source: [olo_ft_ecc_monitor](../../src/ft/vhdl/olo_ft_ecc_monitor.vhd)

## Description

This component implements an **EDAC monitor**: it aggregates the SEC/DED indications of up to 255
fault-tolerant instances (RAMs, FIFOs, delays, AXI masters, scrubbers) into per-channel saturating
counters with sticky DED flags, countable event pulses and a RAM-style read port with per-channel
read-and-clear. It provides the error statistics that housekeeping software needs to track SEU rates
and detect degradation trends.

For an AXI4-Lite attached variant, see [olo_ft_ecc_monitor_axi](./olo_ft_ecc_monitor_axi.md).

## Generics

| Name           | Type     | Default | Description                                                  |
| :------------- | :------- | ------- | :----------------------------------------------------------- |
| Channels_g     | positive | -       | Number of monitored channels (range 1 to 255). One channel is one SEC/DED source pair (one ft instance, or one port of a dual-port one). |
| CounterWidth_g | positive | 16      | Width of each saturating counter (range 1 to 16). The 16-bit maximum lets one channel's SEC and DED counters share a single 32-bit register word. |

## Interfaces

### Control

| Name | In/Out | Length | Default | Description                                                  |
| :--- | :----- | :----- | ------- | :----------------------------------------------------------- |
| Clk  | in     | 1      | -       | Clock                                                        |
| Rst  | in     | 1      | -       | Reset (high-active, synchronous to _Clk_). Clears all counters and sticky flags. |
| Clr  | in     | 1      | '0'     | Synchronous global clear of all counters and sticky flags. An event arriving in the same cycle is counted after the clear (no lost events). |

### Event Inputs

| Name      | In/Out | Length       | Default | Description                                                  |
| :-------- | :----- | :----------- | ------- | :----------------------------------------------------------- |
| In_EccSec | in     | _Channels_g_ | -       | SEC indication per channel.                                  |
| In_EccDed | in     | _Channels_g_ | -       | DED indication per channel.                                  |
| In_Valid  | in     | _Channels_g_ | all '1' | Qualifier per channel; an event is counted in cycles where the flag AND the qualifier are '1'. See [Connecting Sources](#connecting-sources). |

### Status

| Name      | In/Out | Length       | Default | Description                                                  |
| :-------- | :----- | :----------- | ------- | :----------------------------------------------------------- |
| DedSticky | out    | _Channels_g_ | N/A     | Set on the first counted DED per channel, cleared by _Rst_, _Clr_ or a read-and-clear. This is the safety-critical level signal (data corruption occurred on this channel). |
| Evt_Sec   | out    | 1            | N/A     | High for one cycle per clock cycle in which any channel counted a SEC. Directly countable. |
| Evt_Ded   | out    | 1            | N/A     | Same for DED events.                                         |

### Read Port

The read port behaves like an [olo_base_ram_*](../base/olo_base_ram_sdp.md) read with a read latency
of one clock cycle.

| Name       | In/Out | Length                    | Default | Description                                                  |
| :--------- | :----- | :------------------------ | ------- | :----------------------------------------------------------- |
| Rd_Channel | in     | ceil(log2(_Channels_g_))  | 0       | Channel to read (minimum width 1). Indexes beyond _Channels_g_-1 return zeros. |
| Rd_Ena     | in     | 1                         | '0'     | Read strobe.                                                 |
| Rd_Clr     | in     | 1                         | '0'     | Together with _Rd_Ena_: atomically clear the addressed channel (counters and sticky flag) after sampling the read data. An event arriving in the same cycle survives the clear. |
| Rd_SecCnt  | out    | _CounterWidth_g_          | N/A     | SEC counter of the addressed channel.                        |
| Rd_DedCnt  | out    | _CounterWidth_g_          | N/A     | DED counter of the addressed channel.                        |
| Rd_Valid   | out    | 1                         | N/A     | Read data valid, _Rd_Ena_ delayed by one clock cycle.        |

## Detailed Description

### Architecture

The monitor is a single two-process entity without internal storage primitives. The counter file is
deliberately implemented in flip-flops, for two reasons:

1. **Correctness**: multiple channels can count in the same clock cycle, which a RAM-based counter
   file (one write port) cannot express.
2. **Fault tolerance**: all state stays in flip-flops coverable by vendor TMR, following
   [Open Logic Fault-Tolerance Principles](./olo_ft_principles.md). There is no RAM-resident state
   and no codeword inside the monitor; consequently this is the one ft entity **without**
   `ErrInj_BitFlip`/`ErrInj_Valid` ports (there is nothing to flip).

The flip-flop cost is `Channels_g x 2 x CounterWidth_g` plus the sticky vector; for 16 channels at
the default width this is roughly 500 FF before TMR.

### Counting Semantics

- Counters saturate at all-ones and never wrap; a saturated value reads as "at least this many".
- Clear precedence is fixed: read sampling first, then clear (_Clr_ or _Rd_Clr_), then counting. An
  event in the same cycle as a clear is therefore counted after the clear, and a read-and-clear
  returns the pre-clear value. Only _Rst_ discards events.
- _Evt_Sec_/_Evt_Ded_ indicate "at least one channel counted this cycle" with a one-cycle delay,
  countable per cycle like the status pulses of the other ft entities.

### Connecting Sources

The ft entities deliver their status flags in two flavors; the per-channel _In_Valid_ qualifier
serves both:

- **Countable pulses** (scrub status, AXI master write flags): connect the flag directly and leave
  _In_Valid_ at its default '1'.
- **Data-aligned flags** (FIFO/RAM/delay read flags): qualify with the handshake, e.g.
  `In_Valid(i) <= Out_Valid and Out_Ready` for a FIFO or `In_Valid(i) <= RdValid` for a RAM.

When only some channels need qualification, drive the remaining bits with '1'; the all-'1' default
applies only to a fully unconnected port.

The monitor is single-clock. For sources in other clock domains, qualify the flag in its source
domain first and cross it as a pulse via [olo_ft_cc_pulse](./olo_ft_cc_pulse.md).

### Further Information

- [Open Logic Fault-Tolerance Principles - Error Status Flags](./olo_ft_principles.md#error-status-flags)
  describes the SEC/DED flag semantics of the source entities.
- See
  [Open Logic Fault-Tolerance Principles - Constraints That Apply Across the Area](./olo_ft_principles.md#constraints-that-apply-across-the-area)
  for the constraints that apply across the _ft_ area.
