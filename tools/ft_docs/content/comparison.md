# Comparison with Open Logic 4.7.0

This page compares the tag `4.7.0-ft.3` of Open Logic FT with the release 4.7.0 of
[Open Logic](https://github.com/open-logic/open-logic), entity by entity. The tag is based on the upstream branch
`develop` after the release; its VHDL sources are identical with 4.7.0, so every difference listed here comes from the
fork.

In the tables, ✓ means present and unchanged, – means not present. The column _Upstream_ shows where each change
stands in Open Logic:

- **Merged:** part of the Open Logic release 4.7.0, through the linked pull request.
- **Proposed:** proposed to the Open Logic maintainers in the linked issue.
- **Ready:** complete and verified in the fork. Open Logic reviews one pull request at a time, so the pull request
  is opened when the preceding one is merged; "after" names the change it follows.
- **Not yet proposed:** complete and verified in the fork, not yet proposed to Open Logic.

## ft area

| Entity | 4.7.0 | 4.7.0-ft.3 | Upstream |
| --- | --- | --- | --- |
| [olo_ft_pkg_ecc](doc/ft/olo_ft_pkg_ecc.md) | ✓ | ✓ | Merged ([#294](https://github.com/open-logic/open-logic/pull/294)) |
| [olo_ft_ecc_encode](doc/ft/olo_ft_ecc_encode.md), [olo_ft_ecc_decode](doc/ft/olo_ft_ecc_decode.md) | ✓ | ✓ | Merged ([#294](https://github.com/open-logic/open-logic/pull/294)) |
| [olo_ft_ram_sp](doc/ft/olo_ft_ram_sp.md), [olo_ft_ram_sdp](doc/ft/olo_ft_ram_sdp.md), [olo_ft_ram_tdp](doc/ft/olo_ft_ram_tdp.md) | ✓ | ✓ (`olo_ft_ram_sdp`: comments only) | Merged ([#294](https://github.com/open-logic/open-logic/pull/294), [#316](https://github.com/open-logic/open-logic/pull/316), [#319](https://github.com/open-logic/open-logic/pull/319)) |
| [olo_ft_ram_sp_scrub](doc/ft/olo_ft_ram_sp_scrub.md), [olo_ft_ram_sdp_scrub](doc/ft/olo_ft_ram_sdp_scrub.md) (+ `olo_ft_private_scrubber`) | ✓ | ✓ | Merged ([#320](https://github.com/open-logic/open-logic/pull/320)) |
| [olo_ft_fifo_sync](doc/ft/olo_ft_fifo_sync.md), [olo_ft_fifo_packet](doc/ft/olo_ft_fifo_packet.md) | ✓ | ✓ | Merged ([#335](https://github.com/open-logic/open-logic/pull/335)) |
| [olo_ft_fifo_async](doc/ft/olo_ft_fifo_async.md) | – | ✓ Wrapper: ECC encoder, [olo_base_fifo_async](doc/base/olo_base_fifo_async.md) at codeword width, ECC decoder; `SyncStages_g`, `SyncTmr_g` | Ready, after the synchronizer attribute |
| [olo_ft_delay](doc/ft/olo_ft_delay.md), [olo_ft_delay_cfg](doc/ft/olo_ft_delay_cfg.md) | – | ✓ | Ready |
| [olo_ft_axi_master_simple](doc/ft/olo_ft_axi_master_simple.md), [olo_ft_axi_master_full](doc/ft/olo_ft_axi_master_full.md) | – | ✓ | Ready, after the fixes of the base AXI masters ([#361](https://github.com/open-logic/open-logic/issues/361), [#362](https://github.com/open-logic/open-logic/issues/362)) |
| [olo_ft_ecc_monitor](doc/ft/olo_ft_ecc_monitor.md), [olo_ft_ecc_monitor_axi](doc/ft/olo_ft_ecc_monitor_axi.md) | – | ✓ | Ready |
| **Public ft entities** | **9** | **16** | |

## base and axi: additional entities

| Entity | 4.7.0 | 4.7.0-ft.3 | Upstream |
| --- | --- | --- | --- |
| [olo_base_chunker](doc/base/olo_base_chunker.md) | – | ✓ Splits stream packets into chunks of a fixed number of beats, marks the end of the input packet | Not yet proposed |
| [olo_axi_lite_decoder](doc/axi/olo_axi_lite_decoder.md) | – | ✓ Connects one AXI4-Lite master to several register banks in equally sized address windows | Not yet proposed |

## base, axi, intf and fix: entities with changes

The fork changes these entities in three ways:

- **Synchronizer attribute:** the synchronizer registers carry `syn_radhardlevel "none"`, so the automatic TMR of
  the synthesis tool does not insert voters between the synchronizer stages.
- **`SyncTmr_g`:** with `SyncTmr_g = true` every synchronizer is implemented three times with a majority voter after
  the last stage, which masks a single upset. The
  [clock crossing principles](doc/base/clock_crossing_principles.md#radiation-hardening) describe both measures.
- **Safe FSM:** `when others =>` returns the state machine to a safe state instead of doing nothing.

| Entity | 4.7.0 | 4.7.0-ft.3 | Upstream |
| --- | --- | --- | --- |
| [olo_base_cc_bits](doc/base/olo_base_cc_bits.md), [olo_base_cc_reset](doc/base/olo_base_cc_reset.md), [olo_base_reset_gen](doc/base/olo_base_reset_gen.md), [olo_intf_sync](doc/intf/olo_intf_sync.md) | ✓ | + `SyncTmr_g`, synchronizer attribute ¹ | Attribute: Proposed ([#360](https://github.com/open-logic/open-logic/issues/360)); `SyncTmr_g`: Not yet proposed |
| [olo_base_cc_pulse](doc/base/olo_base_cc_pulse.md), [olo_base_cc_simple](doc/base/olo_base_cc_simple.md), [olo_base_cc_status](doc/base/olo_base_cc_status.md), [olo_base_cc_handshake](doc/base/olo_base_cc_handshake.md), [olo_base_fifo_async](doc/base/olo_base_fifo_async.md) | ✓ | + `SyncTmr_g` | Not yet proposed |
| [olo_base_cc_n2xn](doc/base/olo_base_cc_n2xn.md), [olo_base_cc_xn2n](doc/base/olo_base_cc_xn2n.md), [olo_intf_clk_meas](doc/intf/olo_intf_clk_meas.md), [olo_intf_debounce](doc/intf/olo_intf_debounce.md) | ✓ | + `SyncStages_g`, `SyncTmr_g` | Not yet proposed |
| [olo_intf_i2c_master](doc/intf/olo_intf_i2c_master.md), [olo_intf_spi_slave](doc/intf/olo_intf_spi_slave.md), [olo_intf_uart](doc/intf/olo_intf_uart.md) | ✓ | + `SyncStages_g`, `SyncTmr_g`, safe FSM | `SyncTmr_g`: Not yet proposed; safe FSM: Ready |
| [olo_intf_spi_master](doc/intf/olo_intf_spi_master.md), [olo_base_crc_append](doc/base/olo_base_crc_append.md), [olo_base_crc_check](doc/base/olo_base_crc_check.md), [olo_base_fifo_packet](doc/base/olo_base_fifo_packet.md), [olo_axi_lite_slave](doc/axi/olo_axi_lite_slave.md), [olo_fix_bin_div](doc/fix/olo_fix_bin_div.md) | ✓ | Safe FSM | Ready |
| [olo_axi_master_simple](doc/axi/olo_axi_master_simple.md), [olo_axi_master_full](doc/axi/olo_axi_master_full.md) | ✓ | Safe FSM, + `RamStyle_g` | Ready, together with the ft AXI masters |
| [olo_base_pkg_attribute](doc/base/olo_base_pkg_attribute.md) (package) | ✓ | + `syn_radhardlevel`, `SynRadhardlevel_None_c` | Proposed ([#360](https://github.com/open-logic/open-logic/issues/360)) |

¹ Through their instances the attribute also applies to every crossing, FIFO and _intf_ entity built on these four
entities.

All new generics have defaults (`SyncTmr_g = false`, `SyncStages_g = 2`, `RamStyle_g = "auto"`), and no port or
existing generic changed: code written for Open Logic 4.7.0 compiles against 4.7.0-ft.3 without changes.

## Identical in both

- **base** (25, prefix `olo_base_`): `arb_prio`, `arb_rr`, `arb_wrr`, `cam`, `crc`, `decode_firstbit`, `delay`,
  `delay_cfg`, `dyn_sft`, `fifo_sync`, `flowctrl_handler`, `latency_comp`, `pl_stage`, `prbs`, `ram_sp`, `ram_sdp`,
  `ram_tdp`, `rate_limit`, `sample_hold`, `strobe_div`, `strobe_gen`, `tdm_mux`, `wconv_n2m`, `wconv_n2xn`,
  `wconv_xn2n`, and the four private entities
- **axi:** `olo_axi_pl_stage`
- **fix:** the other 35 `olo_fix_*` entities and the four private entities
- **Packages:** all except `olo_base_pkg_attribute`

## Summary

Open Logic 4.7.0 has 94 public entities, 4.7.0-ft.3 has 103; seven of the nine additional entities are in the ft
area, the other two are `olo_base_chunker` and `olo_axi_lite_decoder`.
24 existing entities of the other areas have new generics or a safe FSM. The fork has no separate fault-tolerant
clock crossings: the synchronizers of the base and intf entities are triplicated through `SyncTmr_g`.
