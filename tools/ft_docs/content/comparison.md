# Comparison with Open Logic 4.7.0

This page compares the tag `4.7.0-ft.9` of Open Logic FT with the release 4.7.0 of
[Open Logic](https://github.com/open-logic/open-logic), entity by entity. The tag is based on the upstream branch
`develop` after the release; its VHDL sources are identical with 4.7.0, so every difference listed here comes from the
fork.

In the tables, ✓ means present and unchanged, – means not present. The column _Upstream_ shows where each change
stands in Open Logic:

- **Merged:** part of the Open Logic release 4.7.0, through the linked pull request.
- **Proposed:** proposed to the Open Logic maintainers in the linked issue or pull request.
- **Ready:** complete and verified in the fork. Open Logic reviews one pull request at a time, so the pull request
  is opened when the preceding one is merged; "after" names the change it follows.
- **Not yet proposed:** complete and verified in the fork, not yet proposed to Open Logic.

## ft area

| Entity | 4.7.0 | 4.7.0-ft.9 | Upstream |
| --- | --- | --- | --- |
| [olo_ft_pkg_ecc](doc/ft/olo_ft_pkg_ecc.md) | ✓ | ✓ | Merged ([#294](https://github.com/open-logic/open-logic/pull/294)) |
| [olo_ft_ecc_encode](doc/ft/olo_ft_ecc_encode.md), [olo_ft_ecc_decode](doc/ft/olo_ft_ecc_decode.md) | ✓ | ✓ | Merged ([#294](https://github.com/open-logic/open-logic/pull/294)) |
| [olo_ft_ram_sp](doc/ft/olo_ft_ram_sp.md), [olo_ft_ram_sdp](doc/ft/olo_ft_ram_sdp.md), [olo_ft_ram_tdp](doc/ft/olo_ft_ram_tdp.md) | ✓ | ✓ (`olo_ft_ram_sdp`: comments only) | Merged ([#294](https://github.com/open-logic/open-logic/pull/294), [#316](https://github.com/open-logic/open-logic/pull/316), [#319](https://github.com/open-logic/open-logic/pull/319)) |
| [olo_ft_ram_sp_scrub](doc/ft/olo_ft_ram_sp_scrub.md), [olo_ft_ram_sdp_scrub](doc/ft/olo_ft_ram_sdp_scrub.md) (+ `olo_ft_private_scrubber`) | ✓ | ✓ | Merged ([#320](https://github.com/open-logic/open-logic/pull/320)) |
| [olo_ft_fifo_sync](doc/ft/olo_ft_fifo_sync.md), [olo_ft_fifo_packet](doc/ft/olo_ft_fifo_packet.md) | ✓ | ✓ | Merged ([#335](https://github.com/open-logic/open-logic/pull/335)) |
| [olo_ft_fifo_async](doc/ft/olo_ft_fifo_async.md) | – | ✓ Wrapper: ECC encoder, [olo_base_fifo_async](doc/base/olo_base_fifo_async.md) at codeword width, ECC decoder; `SyncStages_g`, `SyncTmr_g` | Ready, after the synchronizer attribute |
| [olo_ft_delay](doc/ft/olo_ft_delay.md), [olo_ft_delay_cfg](doc/ft/olo_ft_delay_cfg.md) | – | ✓ | Ready |
| [olo_ft_axi_master_simple](doc/ft/olo_ft_axi_master_simple.md), [olo_ft_axi_master_full](doc/ft/olo_ft_axi_master_full.md) (+ [olo_ft_private_fifo_stream](doc/ft/olo_ft_private_fifo_stream.md)) | – | ✓ ECC-protected data buffers with `EccPipeline_g` (register stages in the decoders), `IntFifoDepth_g` (internal FIFOs of the wrapped base master); FIXED bursts and response codes as the base masters | Ready, after the changes of the base AXI masters (see below) |
| [olo_ft_ecc_monitor](doc/ft/olo_ft_ecc_monitor.md), [olo_ft_ecc_monitor_axi](doc/ft/olo_ft_ecc_monitor_axi.md) | – | ✓ | Ready |
| **Public ft entities** | **9** | **16** | |

## base, axi and intf: additional entities

| Entity | 4.7.0 | 4.7.0-ft.9 | Upstream |
| --- | --- | --- | --- |
| [olo_base_chunker](doc/base/olo_base_chunker.md) | – | ✓ Splits stream packets into chunks of a fixed number of beats, marks the end of the input packet | Not yet proposed |
| [olo_base_stream_join](doc/base/olo_base_stream_join.md) | – | ✓ Packs the valid bytes of a stream: input beats may be partial, every output packet is without gaps | Not yet proposed |
| [olo_base_stream_split](doc/base/olo_base_stream_split.md) | – | ✓ Cuts stream packets into segments of a size in bytes given per segment, every segment starts in byte lane 0 | Not yet proposed |
| [olo_base_pkg_gf](doc/base/olo_base_pkg_gf.md) (package) | – | ✓ Galois field GF(2^m) arithmetic and Reed-Solomon code tables | Not yet proposed |
| [olo_base_rs_encode](doc/base/olo_base_rs_encode.md) | – | ✓ Streaming Reed-Solomon encoder for any GF(2^m) code: interleaving, shortened blocks, dual basis (for example CCSDS 131.0-B-5) | Not yet proposed |
| [olo_base_rs_decode](doc/base/olo_base_rs_decode.md) | – | ✓ Streaming Reed-Solomon decoder: corrects up to t symbol errors per codeword, status per codeword | Not yet proposed |
| [olo_axi_lite_decoder](doc/axi/olo_axi_lite_decoder.md) | – | ✓ Connects one AXI4-Lite master to several register banks in equally sized address windows | Not yet proposed |
| [olo_intf_can](doc/intf/olo_intf_can.md) (+ package `olo_intf_pkg_can`) | – | ✓ CAN 2.0B controller: standard and extended frames, error handling, fault confinement, bit timing set at runtime | Not yet proposed |

## base, axi, intf and fix: entities with changes

The fork changes these entities in five ways:

- **Synchronizer attribute:** the synchronizer registers carry `syn_radhardlevel "none"`, so the automatic TMR of
  the synthesis tool does not insert voters between the synchronizer stages.
- **`SyncTmr_g`:** with `SyncTmr_g = true` every synchronizer is implemented three times with a majority voter after
  the last stage, which masks a single upset. The
  [clock crossing principles](doc/base/clock_crossing_principles.md#radiation-hardening) describe both measures.
- **Safe FSM:** `when others =>` returns the state machine to a safe state instead of doing nothing.
- **AXI master features:** FIXED bursts (`CmdWr_Fixed`, `CmdRd_Fixed`), the response code of a failed command
  (`Wr_ErrorResp`, `Rd_ErrorResp`) and, in `olo_axi_master_full`, consecutive commands without gaps.
- **Bug fixes:** fixes of Open Logic 4.7.0 that are not yet merged upstream.

| Entity | 4.7.0 | 4.7.0-ft.9 | Upstream |
| --- | --- | --- | --- |
| [olo_base_cc_bits](doc/base/olo_base_cc_bits.md), [olo_base_cc_reset](doc/base/olo_base_cc_reset.md), [olo_base_reset_gen](doc/base/olo_base_reset_gen.md), [olo_intf_sync](doc/intf/olo_intf_sync.md) | ✓ | + `SyncTmr_g`, synchronizer attribute ¹ | Attribute: Proposed ([#360](https://github.com/open-logic/open-logic/issues/360)); `SyncTmr_g`: Not yet proposed |
| [olo_base_cc_pulse](doc/base/olo_base_cc_pulse.md), [olo_base_cc_simple](doc/base/olo_base_cc_simple.md), [olo_base_cc_status](doc/base/olo_base_cc_status.md), [olo_base_cc_handshake](doc/base/olo_base_cc_handshake.md), [olo_base_fifo_async](doc/base/olo_base_fifo_async.md) | ✓ | + `SyncTmr_g` | Not yet proposed |
| [olo_base_cc_n2xn](doc/base/olo_base_cc_n2xn.md), [olo_base_cc_xn2n](doc/base/olo_base_cc_xn2n.md), [olo_intf_clk_meas](doc/intf/olo_intf_clk_meas.md), [olo_intf_debounce](doc/intf/olo_intf_debounce.md) | ✓ | + `SyncStages_g`, `SyncTmr_g` | Not yet proposed |
| [olo_intf_spi_slave](doc/intf/olo_intf_spi_slave.md), [olo_intf_uart](doc/intf/olo_intf_uart.md) | ✓ | + `SyncStages_g`, `SyncTmr_g`, safe FSM | `SyncTmr_g`: Not yet proposed; safe FSM: Ready |
| [olo_intf_i2c_master](doc/intf/olo_intf_i2c_master.md) | ✓ | + `SyncStages_g`, `SyncTmr_g`, safe FSM; fix: the simulation checks of the command sequence evaluate accepted commands at the clock edge, so a command that settles one delta cycle after `Cmd_Valid` is no longer reported | `SyncTmr_g`, fix: Not yet proposed; safe FSM: Ready |
| [olo_intf_spi_master](doc/intf/olo_intf_spi_master.md), [olo_base_crc_append](doc/base/olo_base_crc_append.md), [olo_base_crc_check](doc/base/olo_base_crc_check.md), [olo_axi_lite_slave](doc/axi/olo_axi_lite_slave.md), [olo_fix_bin_div](doc/fix/olo_fix_bin_div.md) | ✓ | Safe FSM | Ready |
| [olo_base_fifo_packet](doc/base/olo_base_fifo_packet.md) | ✓ | Safe FSM; documentation: `In_IsDropped` also for packets above `MaxPacketSize_g` | Safe FSM: Ready; documentation: Not yet proposed |
| [olo_base_wconv_n2m](doc/base/olo_base_wconv_n2m.md) | ✓ | Fix: `Out_Be` is driven for equal input and output widths (`In_Be` with `UseBe_g = true`, all '1' otherwise); fix: the simulation check of partial byte enables evaluates accepted beats at the clock edge | Not yet proposed |
| [olo_axi_master_simple](doc/axi/olo_axi_master_simple.md) | ✓ | Safe FSM, + `RamStyle_g`; AXI master features: FIXED bursts, response codes; fix: `Rd_Error` also for an error on a non-last beat of a burst, no error reported for the transfer after a failed one, no metavalue warnings before the first transfer, correct address of split transfers with `AxiMaxBeats_g` below the bytes per beat, beat counts of the right width for 4 kB splits of wide data and small `UserTransactionSizeBits_g`; documentation: throughput limits | Fixes: Proposed ([#366](https://github.com/open-logic/open-logic/pull/366)); safe FSM and `RamStyle_g`: Ready, together with the ft AXI masters; AXI master features, documentation: Not yet proposed |
| [olo_axi_master_full](doc/axi/olo_axi_master_full.md) | ✓ | Safe FSM, + `RamStyle_g`; AXI master features: FIXED bursts, response codes, consecutive commands without gaps; fix: writes with `UserDataWidth_g = 8`, correct address of split transfers with `AxiMaxBeats_g` below the bytes per beat (through `olo_axi_master_simple`), `AxiDataWidth_g = 8` elaborates and has correct first and last byte enables, `AxiAddrWidth_g` down to `UserTransactionSizeBits_g` + 2 (the documented limit is now `UserTransactionSizeBits_g < AxiAddrWidth_g - 1`, for 8-bit data `< AxiAddrWidth_g`), write commands of the largest sizes complete (word count), a command that is valid at the release of the reset is executed once | Fixes except the reset release: Proposed ([#365](https://github.com/open-logic/open-logic/pull/365), [#366](https://github.com/open-logic/open-logic/pull/366)); reset release fix, AXI master features: Not yet proposed; safe FSM and `RamStyle_g`: Ready, together with the ft AXI masters |
| [olo_base_pkg_attribute](doc/base/olo_base_pkg_attribute.md) (package) | ✓ | + `syn_radhardlevel`, `SynRadhardlevel_None_c` | Proposed ([#360](https://github.com/open-logic/open-logic/issues/360)) |

¹ Through their instances the attribute also applies to every crossing, FIFO and _intf_ entity built on these four
entities.

All new generics and input ports have defaults (`SyncTmr_g = false`, `SyncStages_g = 2`, `RamStyle_g = "auto"`,
`CmdWr_Fixed = '0'`, `CmdRd_Fixed = '0'`), and no existing port or generic changed: code written for Open Logic 4.7.0
compiles against 4.7.0-ft.9 without changes.
Test benches built on the AXI slave verification component `olo_test_axi_slave_vc` (`test/tb`) need one change:
`push_r` and `push_r_arbitrary` take `error_code` instead of `resp`, and the new `error_beat` selects the beat that
carries the error (Proposed, [#366](https://github.com/open-logic/open-logic/pull/366)). `expect_burst_write_aligned`
and `push_burst_read_aligned` take the burst type as an optional argument (default INCR). The new verification
component `olo_test_axis_slave_vc` compares every TDATA bit of an AXI4-Stream, also for data widths that are not a
multiple of 8 bits, which the VUnit stream slave does not (Not yet proposed).

## Identical in both

- **base** (24, prefix `olo_base_`): `arb_prio`, `arb_rr`, `arb_wrr`, `cam`, `crc`, `decode_firstbit`, `delay`,
  `delay_cfg`, `dyn_sft`, `fifo_sync`, `flowctrl_handler`, `latency_comp`, `pl_stage`, `prbs`, `ram_sp`, `ram_sdp`,
  `ram_tdp`, `rate_limit`, `sample_hold`, `strobe_div`, `strobe_gen`, `tdm_mux`, `wconv_n2xn`, `wconv_xn2n`, and the
  four private entities of 4.7.0
- **axi:** `olo_axi_pl_stage`
- **fix:** the other 35 `olo_fix_*` entities and the four private entities
- **Packages:** all packages of 4.7.0 except `olo_base_pkg_attribute`

## Summary

Open Logic 4.7.0 has 94 public entities, 4.7.0-ft.9 has 108. Seven of the 14 additional entities are in the ft area;
the other seven are `olo_base_chunker`, `olo_base_stream_join`, `olo_base_stream_split`, `olo_base_rs_encode`,
`olo_base_rs_decode`, `olo_axi_lite_decoder` and `olo_intf_can`, with the new packages `olo_base_pkg_gf` and
`olo_intf_pkg_can`.
25 existing entities of the other areas differ from 4.7.0 (new generics or ports, a safe FSM, bug fixes); four of
them have bug fixes.
The fork has no separate fault-tolerant clock crossings: the synchronizers of the base and intf entities are
triplicated through `SyncTmr_g`.
