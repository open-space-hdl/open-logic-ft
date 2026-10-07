<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_reset_gen

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_reset_gen.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_reset_gen.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_reset_gen.json?cacheSeconds=0)

VHDL Source: [olo_ft_reset_gen](../../src/ft/vhdl/olo_ft_reset_gen.vhd)

## Description

This component is a **TMR-hardened reset generator**. A single-event upset (SEU) on any flip-flop of the component
neither asserts the reset nor shortens a reset pulse.

It is the fault-tolerant counterpart of [olo_base_reset_gen](../base/olo_base_reset_gen.md) with the same interface
and the same behavior: it generates reset pulses of a specified minimum duration after FPGA configuration and upon
request (reset input), detects the reset input asynchronously and always de-asserts the reset synchronously. Assertion
is asynchronous or synchronous, depending on the users choice.

In a design with several clock domains, one _olo_ft_reset_gen_ per clock domain synchronizes the reset of that domain.
Without TMR, an upset in the reset synchronizer of a domain resets the whole domain.

**Note:** Because the reset input is detected asynchronously, it is important that this input is glitch-free.

**WARNING:** Reset assertion upon FPGA configuration relies on the **target technology supporting specific FF
initialization state**. For technologies which do not support specifying FF initialization state (e.g. Microchip
devices) an external reset signal must be connected to _RstIn_. See
[olo_base_reset_gen](../base/olo_base_reset_gen.md) for details.

## Generics

| Name               | Type      | Default | Description                                                  |
| :----------------- | :-------- | ------- | :----------------------------------------------------------- |
| RstPulseCycles_g   | positive  | 3       | Minimum duration of the reset pulse in clock cycles<br />Range: 3 ... 2^31-1 |
| RstInPolarity_g    | std_logic | '1'     | Polarity of _RstIn_.<br />'1' - Active High<br />'0' - Active Low |
| AsyncResetOutput_g | boolean   | false   | True = _RstOut_ is asserted asynchronously (_RstIn_ is forwarded even in absence of _Clk_ activity)<br />False = _RstOut_ is asserted synchronously (upon _Clk_ rising edge). |
| SyncStages_g       | positive  | 2       | Number of synchronization stages for the multi-stage synchronizer in case of _AsyncResetOutput_g_=false. <br />This generic is not having any effect for _AsyncResetOutput_g_=true.<br>Range: 2 ... 4 |

## Interfaces

| Name   | In/Out | Length | Default               | Description                                                  |
| :----- | :----- | :----- | :-------------------- | :----------------------------------------------------------- |
| Clk    | in     | 1      | -                     | Clock                                                        |
| RstOut | out    | 1      | -                     | Reset output (high-active, synchronous to Clk)<br />**Note**: The output is always high-active according to _Open Logic_ guidelines. |
| RstIn  | in     | 1      | not _RstInPolarity_g_ | Reset input. The reset is detected asynchronously - any glitches on this signal lead to a reset pulse being generated.<br />The input is optional. If reset shall only be asserted after FPGA configuration, it can be left floating (limited to target technologies supporting specifying the FF initialization state). |

## Architecture

The architecture follows _olo_base_reset_gen_ with every register triplicated:

```text
RstIn -+-> RstSyncChain[A] -> DsSync[A] -+
       +-> RstSyncChain[B] -> DsSync[B] -+-> vote -> RstSync -+-> pulse prolongation -> vote -> RstOut
       +-> RstSyncChain[C] -> DsSync[C] -+                     |   (PulseCnt[A,B,C],
                                                               |    RstPulse[A,B,C])
```

- **Reset synchronizers:** three independent chains. Each chain is set asynchronously by _RstIn_ and shifts in '0'
  after the reset input is released. For _AsyncResetOutput_g_=false, three independent multi-stage synchronizers
  (_DsSync_) follow. The outputs of the three chains are combined by a majority voter. An upset in one chain is
  shifted out after a few clock cycles and masked by the voter in the meantime.
- **Pulse prolongation** (only for _RstPulseCycles_g_ > 3): counter and pulse register are triplicated. The next value
  of every copy is computed from the voted state, so an upset copy is repaired at the next clock edge.
- **Output:** the voted pulse register (for _AsyncResetOutput_g_=true combined with the voted output of the reset
  synchronizers, so the reset is also forwarded in the absence of clock activity).

### Limitations

- TMR masks one upset per register and clock cycle. Two upsets in different copies within the time an upset needs to
  be shifted out of a synchronizer chain (or to be repaired) are not masked.
- The three chains sample the release of _RstIn_ independently, so they may release one clock cycle apart. The voted
  output releases with the second chain.
- The voters are not triplicated. The design targets upsets of storage elements (SEU), not single-event transients in
  combinational logic.

### Synthesis Attributes

- **`syn_radhardlevel = "none"`** at the architecture level prevents tools like Synplify (Microchip Libero) from
  triplicating the already-triplicated registers.
- `dont_touch`, `dont_merge`, `preserve`, `syn_preserve` and `syn_keep` on all TMR copies prevent the synthesis tool
  from merging the copies. The synchronizer chains additionally carry the attributes of _olo_base_reset_gen_
  (`shreg_extract`, `syn_srlstyle`, `async_reg`).

The entity requires roughly three times the flip-flops of _olo_base_reset_gen_ plus the voters.

## Constraints

The same constraints as for _olo_base_reset_gen_ apply: a `set_false_path` (or `set_max_delay -datapath_only`)
constraint for the _RstIn_ input and, for _AsyncResetOutput_g_=false, a `set_max_delay -datapath_only` of one clock
period from _RstSyncChain_ to _DsSync_.

The register names match _olo_base_reset_gen_, so in _AMD Vivado_ its scoped constraint file can be used:
`read_xdc -ref olo_ft_reset_gen <path>/src/base/tcl/olo_base_reset_gen.tcl`. Note that the scoped constraints for
automatic constraining are only loaded for the _olo_base_ entities.
