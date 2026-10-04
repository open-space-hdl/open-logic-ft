<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_cc_simple

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_cc_simple.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_cc_simple.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_cc_simple.json?cacheSeconds=0)

VHDL Source: [olo_ft_cc_simple](../../src/ft/vhdl/olo_ft_cc_simple.vhd)

## Description

This component is a **TMR-hardened clock crossing** for transferring single values from one clock domain to another
(completely asynchronous clocks). A single-event upset (SEU) on any flip-flop of the crossing is masked: it neither
corrupts the transferred data nor produces a spurious or lost _Out_Valid_ pulse.

It is the fault-tolerant counterpart of [olo_base_cc_simple](../base/olo_base_cc_simple.md) with the same interface and
the same behavior. In both clock domains the valid samples are marked with a Valid signal according to the AXI-S
specification but back-pressure (Ready) is not handled.

**For the entity to work correctly, the data-rate must be significantly lower ((3+SyncStages_g) x lower) than the
slower clock frequency.** This is the same requirement as for _olo_base_cc_simple_.

This block follows the general [clock-crossing principles](../base/clock_crossing_principles.md). Read through them for
more information.

## Generics

| Name         | Type     | Default | Description                                            |
| :----------- | :------- | ------- | :----------------------------------------------------- |
| Width_g      | positive | 1       | Width of the data-signal to clock-cross                |
| SyncStages_g | positive | 2       | Number of synchronization stages. <br />Range: 2 ... 4 |

## Interfaces

| Name       | In/Out | Length    | Default | Description                                                  |
| :--------- | :----- | :-------- | ------- | :----------------------------------------------------------- |
| In_Clk     | in     | 1         | -       | Source clock                                                 |
| In_RstIn   | in     | 1         | '0'     | Reset input (high-active, synchronous to _In_Clk_)           |
| In_RstOut  | out    | 1         | N/A     | Reset output (see [clock-crossing principles](../base/clock_crossing_principles.md), synchronous to _In_Clk_) |
| In_Data    | in     | _Width_g_ | -       | Input data (synchronous to _In_Clk_)                         |
| In_Valid   | in     | 1         | -       | AXI4-Stream handshaking signal for _In_Data_                 |
| Out_Clk    | in     | 1         | -       | Destination clock                                            |
| Out_RstIn  | in     | 1         | '0'     | Reset input (high-active, synchronous to _Out_Clk_)          |
| Out_RstOut | out    | 1         | N/A     | Reset output (see [clock-crossing principles](../base/clock_crossing_principles.md), synchronous to _Out_Clk_) |
| Out_Data   | out    | _Width_g_ | N/A     | Output data (synchronous to _Out_Clk_)                       |
| Out_Valid  | out    | 1         | N/A     | AXI4-Stream handshaking signal for _Out_Data_                |

## Architecture

The architecture follows _olo_base_cc_simple_: _In_Data_ is latched when _In_Valid_ is asserted, the valid pulse is
clock-crossed, and in the output clock domain the latched data is sampled when the valid pulse arrives. A specific
clock crossing for the data is not required because the latched data is guaranteed to be stable while the valid pulse
crosses.

Every storage element of the data and valid paths is triplicated (copies A, B and C) and followed by a majority
voter:

```text
              In_Clk domain             :            Out_Clk domain
                                        :
In_Valid --+--> olo_ft_private_cc_toggle --> VldOutI --+--> OutValid[A,B,C] --> vote --> Out_Valid
           |                            :              |
           | load                       :              | load
           v                            :              v
In_Data -----> DataLatchIn[A] ----------:-----> Out_Data_Sig[A] --+
         +---> DataLatchIn[B] ----------:-----> Out_Data_Sig[B] --+--> vote --> Out_Data
         +---> DataLatchIn[C] ----------:-----> Out_Data_Sig[C] --+
               (hold: voted value)      :       (hold: voted value)

In_RstIn / Out_RstIn --> olo_ft_cc_reset --> In_RstOut / Out_RstOut
```

- **Data latch (In_Clk):** three copies load _In_Data_ on _In_Valid_. Otherwise every copy reloads the voted value.
- **Valid crossing:** _In_Valid_ is crossed by [olo_ft_private_cc_toggle](./olo_ft_private_cc_toggle.md): a
  triplicated toggle register, an [olo_ft_cc_bits](./olo_ft_cc_bits.md) TMR synchronizer and a triplicated edge
  detector. It produces exactly one single-cycle pulse per input pulse.
- **Output registers (Out_Clk):** each copy of the output data samples its own copy of the data latch (A from A, B
  from B, C from C) when the valid pulse arrives, so there is no logic on the asynchronous data path. Otherwise every
  copy reloads the voted value. _Out_Valid_ is a triplicated register followed by a voter.
- **Reset crossing:** [olo_ft_cc_reset](./olo_ft_cc_reset.md).

The latency in clock cycles is identical to _olo_base_cc_simple_.

## Fault Tolerance

### Protection Concept

| State                       | Clock domain | Protection                                                         |
| :-------------------------- | :----------- | :----------------------------------------------------------------- |
| Data latch                  | _In_Clk_     | Three copies, voted hold (an upset copy is repaired at the next edge) |
| Valid toggle                | _In_Clk_     | Three copies, next value computed from the voted value             |
| Valid synchronizer          | both         | [olo_ft_cc_bits](./olo_ft_cc_bits.md): three chains with voter     |
| Valid edge detector         | _Out_Clk_    | Three copies with voter                                            |
| _Out_Valid_ register        | _Out_Clk_    | Three copies with voter                                            |
| Output data register        | _Out_Clk_    | Three copies, voted hold (an upset copy is repaired at the next edge) |
| Reset crossing              | both         | [olo_ft_cc_reset](./olo_ft_cc_reset.md)                            |

The hold path of every register uses the **voted** value instead of the register's own value. An upset copy is
therefore repaired at the next clock edge and upsets cannot accumulate while a value is held for a long time. With a
plain triplication (each copy holding its own value), an upset in copy A followed much later by an upset in copy B of
the same bit would defeat the voter.

The valid pulse is crossed with a toggle synchronizer (like in _olo_base_cc_pulse_) instead of
[olo_ft_cc_pulse](./olo_ft_cc_pulse.md). The toggle synchronizer works for any clock ratio, supports 2 to 4 sync
stages and produces a single-cycle output pulse, so the timing behavior of _olo_base_cc_simple_ is retained. Because a
toggle is a level, the three synchronizer chains of [olo_ft_cc_bits](./olo_ft_cc_bits.md) may see a toggle one clock
cycle apart, but the voted toggle still changes exactly once per input pulse. A single upset can at most delay the
change until the last of the three chains sees the toggle, which is within the worst-case latency of a non-hardened
synchronizer, but it never produces a second change. The underlying analysis of TMR synchronizers is given in [1].

### Limitations

- TMR masks one upset per register and clock cycle. Two upsets in different copies of the same register within one
  clock cycle are not masked.
- The voters and the combinational logic are not triplicated. The design targets upsets of storage elements (SEU),
  not single-event transients in combinational logic. This is the same fault model as for the other
  _olo_ft_cc_\<...\>_ entities.
- The reset crossing [olo_ft_cc_reset](./olo_ft_cc_reset.md) protects its acknowledge paths with TMR. Its
  request-path registers rely on vendor TMR (see its documentation). An upset there leads to a spurious reset of both
  clock domains (visible on _In_RstOut_ / _Out_RstOut_), not to silently corrupted data.

### Synthesis Attributes

- **`syn_radhardlevel = "none"`** at the architecture level prevents tools like Synplify (Microchip Libero) from
  triplicating the already-triplicated registers.
- `dont_touch`, `dont_merge`, `preserve`, `syn_preserve` and `syn_keep` on all TMR copies prevent the synthesis tool
  from merging the copies (they have identical inputs and would otherwise be optimized into one register).

The entity requires roughly three times the flip-flops of _olo_base_cc_simple_ (six registers of _Width_g_ bits for
the data) plus one voter per bit.

## Constraints

The same constraints as for _olo_base_cc_simple_ apply, see
[clock-crossing principles](../base/clock_crossing_principles.md).

Note that the scoped constraints for automatic constraining in _AMD Vivado_ are only provided for the _olo_base_
clock crossings. Constrain the clock crossings of _olo_ft_ entities manually.

## References

[1] Y. Li, B. Nelson, and M. Wirthlin, "Synchronization Techniques for Crossing Multiple Clock
Domains in FPGA-Based TMR Circuits," IEEE Transactions on Nuclear Science, vol. 57, no. 6,
pp. 3506-3514, Dec. 2010. DOI: 10.1109/TNS.2010.2086075
