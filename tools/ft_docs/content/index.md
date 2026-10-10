# Open Logic FT

[![TRL 3](assets/images/trl-3.svg)](https://openspacehdl.org/trl/)

Open Logic FT is the fault-tolerant fork of [Open Logic](https://github.com/open-logic/open-logic), the VHDL standard
library of FPGA building blocks. It adds the _ft_ area: building blocks for designs in radiation environments such as
spacecraft, where single event upsets flip bits in RAM cells and registers. The RAMs and FIFOs of the area are protected
by a SECDED code (single error correction, double error detection); the clock domain crossings, the reset generator and
the synchronizer are triplicated with majority voting (TMR).

The fork is maintained by [Open Space HDL](https://openspacehdl.org). Finished entities go to upstream Open Logic, one
pull request at a time; everything else in the fork is identical to Open Logic.

## What the fork adds

The cross-cutting concepts (codeword layout, error injection, status flags, ECC pipeline) are described once in the
[fault-tolerance principles](doc/ft/olo_ft_principles.md). The [entity list](doc/EntityList.md#ft) describes every
entity in one line.

| Group | Entities | Upstream Open Logic |
| --- | --- | --- |
| ECC package and codec | [olo_ft_pkg_ecc](doc/ft/olo_ft_pkg_ecc.md), [olo_ft_ecc_encode](doc/ft/olo_ft_ecc_encode.md), [olo_ft_ecc_decode](doc/ft/olo_ft_ecc_decode.md) | Since 4.7.0 |
| RAMs | [olo_ft_ram_sp](doc/ft/olo_ft_ram_sp.md), [olo_ft_ram_sdp](doc/ft/olo_ft_ram_sdp.md), [olo_ft_ram_tdp](doc/ft/olo_ft_ram_tdp.md) | Since 4.7.0 |
| RAMs with background scrubbing | [olo_ft_ram_sp_scrub](doc/ft/olo_ft_ram_sp_scrub.md), [olo_ft_ram_sdp_scrub](doc/ft/olo_ft_ram_sdp_scrub.md) | Since 4.7.0 |
| FIFOs | [olo_ft_fifo_sync](doc/ft/olo_ft_fifo_sync.md), [olo_ft_fifo_packet](doc/ft/olo_ft_fifo_packet.md) | Since 4.7.0 |
| Asynchronous FIFO | [olo_ft_fifo_async](doc/ft/olo_ft_fifo_async.md) | Fork only |
| Clock crossings (TMR) | [olo_ft_cc_reset](doc/ft/olo_ft_cc_reset.md), [olo_ft_cc_bits](doc/ft/olo_ft_cc_bits.md), [olo_ft_cc_pulse](doc/ft/olo_ft_cc_pulse.md), [olo_ft_cc_simple](doc/ft/olo_ft_cc_simple.md), [olo_ft_cc_status](doc/ft/olo_ft_cc_status.md), [olo_ft_cc_handshake](doc/ft/olo_ft_cc_handshake.md) | Fork only |
| Reset generator and synchronizer (TMR) | [olo_ft_reset_gen](doc/ft/olo_ft_reset_gen.md), [olo_ft_sync](doc/ft/olo_ft_sync.md) | Fork only |
| Delays | [olo_ft_delay](doc/ft/olo_ft_delay.md), [olo_ft_delay_cfg](doc/ft/olo_ft_delay_cfg.md) | Fork only |
| AXI masters | [olo_ft_axi_master_simple](doc/ft/olo_ft_axi_master_simple.md), [olo_ft_axi_master_full](doc/ft/olo_ft_axi_master_full.md) | Fork only |
| EDAC monitoring | [olo_ft_ecc_monitor](doc/ft/olo_ft_ecc_monitor.md), [olo_ft_ecc_monitor_axi](doc/ft/olo_ft_ecc_monitor_axi.md) | Fork only |

Where an ft entity has a _base_ or _intf_ counterpart, it keeps that interface and adds only what fault tolerance
needs: the ECC-protected entities add error injection inputs, single and double error status outputs and the ECC
pipeline settings, the TMR entities add only TMR-specific generics. Besides the ft area, the fork gives the state
machines of several base, intf, fix and axi entities a safe recovery state.

## Using the fork

The fork replaces Open Logic in a project; the library name (`olo`), the compile order and the tool scripts are the
same, see [How to](doc/HowTo.md). Projects include it as a git submodule and pin a tag. Tags are named
`<upstream version>-ft.<n>` and mark a state of the branch `fault-tolerant` whose checks passed; the first is
`4.7.0-ft.1`.

```shell
git submodule add -b fault-tolerant https://github.com/open-space-hdl/open-logic-ft.git open-logic
git -C open-logic checkout 4.7.0-ft.1
git add open-logic
```

| Branch | Content |
| --- | --- |
| `fault-tolerant` | Default branch: upstream `develop` plus all ft entities as a linear series of commits |
| `feature/<name>` | One upstream pull request each, cut from upstream `develop` |
| `main`, `develop` | Unchanged mirrors of upstream Open Logic |

## Verification

Every push to `fault-tolerant` runs the workflow `FT-Backlog-Check`: GHDL simulation of all configurations of the ft
area and the minimal set of the other areas, VSG linting, markdownlint and the check that every ft entity is part of
the synthesis inference test. The tests of the TMR entities force upsets into the registers of single chains and check
that the voted outputs are not affected. The tag `4.7.0-ft.1` passed the full regression of the library (7784 tests)
with GHDL.

## Technology readiness

The ft entities are at **TRL 3**: fully verified by simulation (including the injected errors and upsets described
above), not yet tested on hardware, no flight heritage. This also applies to the ft entities that are already part
of Open Logic. The [TRL page](https://openspacehdl.org/trl/) explains what the levels mean for an IP core.

| Next level | What is needed | State |
| --- | --- | --- |
| TRL 4 | The ft entities in operation in a hardware design (e.g. inside OpenWire or OpenFibre on an evaluation board); errors injected through the error injection inputs on hardware, scrubbers running; hardware test report | Open |
| TRL 5 | Single-event effects test (beam test) on a radiation-tolerant FPGA that confirms the effectiveness of ECC, scrubbing and TMR and quantifies the error rates | Open |

## Used by

| Project | Content |
| --- | --- |
| [OpenWire](https://openspacehdl.org/openwire/) | Open SpaceWire implementation based on the Open Logic VHDL library |
| [OpenFibre](https://openspacehdl.org/openfibre/) | Open SpaceFibre implementation based on the Open Logic VHDL library |
| [OpenRMAP](https://openspacehdl.org/openrmap/) | Open implementation of the Remote Memory Access Protocol for SpaceWire and SpaceFibre networks |

## Licence

Open Logic FT is licensed under the [PSI HDL Library License, Version 1.0](License.txt), the licence of Open Logic
(LGPL 2.1 with an exception for binaries, see [LGPL2_1.txt](LGPL2_1.txt)). The other pages of this site are the
documentation of Open Logic, rendered from the branch `fault-tolerant`; [About Open Logic](Readme.md) introduces the
library and its maintainer.
