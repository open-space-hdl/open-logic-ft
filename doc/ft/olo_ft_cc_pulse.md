<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_cc_pulse

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_cc_pulse.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_cc_pulse.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_cc_pulse.json?cacheSeconds=0)

VHDL Source: [olo_ft_cc_pulse](../../src/ft/vhdl/olo_ft_cc_pulse.vhd)

## Description

This component is a **TMR-hardened pulse clock domain crossing**. A single-event upset (SEU) on any flip-flop of the
crossing is masked: it neither creates nor removes an output pulse.

It is the fault-tolerant counterpart of [olo_base_cc_pulse](../base/olo_base_cc_pulse.md) with the same interface and
the same behavior: every single-cycle pulse on _In_Pulse_ produces exactly one single-cycle pulse on _Out_Pulse_. The
entity works for any clock ratio.

The pulse frequency must be significantly lower than the slower clock frequency. Two pulses on the same bit must be
at least _3 + SyncStages_g_ cycles of the slower clock apart. Pulses that follow each other more closely may be
merged into one output pulse.

This block follows the general [clock-crossing principles](../base/clock_crossing_principles.md). Read through them for
more information.

## Generics

| Name         | Type     | Default | Description                                            |
| :----------- | :------- | ------- | :----------------------------------------------------- |
| NumPulses_g  | positive | 1       | Number of independent pulse channels                   |
| SyncStages_g | positive | 2       | Number of synchronization stages. <br />Range: 2 ... 4 |

## Interfaces

| Name       | In/Out | Length        | Default | Description                                                  |
| :--------- | :----- | :------------ | ------- | :----------------------------------------------------------- |
| In_Clk     | in     | 1             | -       | Source clock                                                 |
| In_RstIn   | in     | 1             | '0'     | Reset input (high-active, synchronous to _In_Clk_)           |
| In_RstOut  | out    | 1             | N/A     | Reset output (see [clock-crossing principles](../base/clock_crossing_principles.md), synchronous to _In_Clk_) |
| In_Pulse   | in     | _NumPulses_g_ | -       | Input pulses (synchronous to _In_Clk_)                       |
| Out_Clk    | in     | 1             | -       | Destination clock                                            |
| Out_RstIn  | in     | 1             | '0'     | Reset input (high-active, synchronous to _Out_Clk_)          |
| Out_RstOut | out    | 1             | N/A     | Reset output (see [clock-crossing principles](../base/clock_crossing_principles.md), synchronous to _Out_Clk_) |
| Out_Pulse  | out    | _NumPulses_g_ | N/A     | Output pulses (synchronous to _Out_Clk_), one single-cycle pulse per input pulse |

## Architecture

The architecture follows _olo_base_cc_pulse_: every input pulse toggles a level, the level crosses the clock domain
and an edge detector converts every change of the level back into a single-cycle pulse. Each pulse channel is one
[olo_ft_private_cc_toggle](./olo_ft_private_cc_toggle.md); the resets of both domains are crossed once by
[olo_ft_cc_reset](./olo_ft_cc_reset.md).

```text
           In_Clk domain               :                Out_Clk domain
                                       :
In_Pulse --> XOR --> ToggleIn --> olo_ft_cc_bits --> ToggleOut --+-------------> XOR --> Out_Pulse
              ^         |              :          (3 chains +    |               ^
              |         v              :           voter)        v               |
            vote <- ToggleLast[A,B,C]  :                 ToggleOutLast[A,B,C] -> vote
```

- **Toggle register (_In_Clk_):** three copies. The next value of every copy is computed from the voted value, so an
  upset copy is repaired at the next clock edge.
- **Synchronizer:** [olo_ft_cc_bits](./olo_ft_cc_bits.md) with three independent synchronizer chains and a majority
  voter. Because a toggle is a level, the three chains may see a toggle one clock cycle apart, but the voted level
  still changes exactly once per input pulse.
- **Edge detector (_Out_Clk_):** three copies of the last level with a voter.

The design contains no latches. Every path between the clock domains starts and ends at a flip-flop and is
constrained like the paths of [olo_ft_cc_bits](./olo_ft_cc_bits.md).

### Limitations

- TMR masks one upset per register and clock cycle. Two upsets in different copies of the same register within one
  clock cycle are not masked.
- The voters and the combinational logic are not triplicated. The design targets upsets of storage elements (SEU),
  not single-event transients in combinational logic.
- The reset crossing [olo_ft_cc_reset](./olo_ft_cc_reset.md) protects its acknowledge paths with TMR. An upset in its
  request-path registers leads to a spurious reset of both clock domains, not to a spurious output pulse.

### History

Earlier versions implemented the short-pulse synchronizer of Li, Nelson and Wirthlin [1] (Fig. 14) with a set/reset
latch per TMR copy. FPGA tools map such a latch to a transparent latch whose gate and data input both follow the
input pulse, so the end of the pulse races the closing of the latch (a pulse can be lost), and the paths through the
latch are not timed. The toggle-based architecture avoids latches and supports any clock ratio.

## Constraints

The same constraints as for _olo_base_cc_pulse_ apply, see
[clock-crossing principles](../base/clock_crossing_principles.md).

Note that the scoped constraints for automatic constraining in _AMD Vivado_ are only provided for the _olo_base_
clock crossings. Constrain the clock crossings of _olo_ft_ entities manually.

## References

[1] Y. Li, B. Nelson, and M. Wirthlin, "Synchronization Techniques for Crossing Multiple Clock
Domains in FPGA-Based TMR Circuits," IEEE Transactions on Nuclear Science, vol. 57, no. 6,
pp. 3506-3514, Dec. 2010. DOI: 10.1109/TNS.2010.2086075
