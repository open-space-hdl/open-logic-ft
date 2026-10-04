<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_private_cc_toggle

[Back to **Entity List**](../EntityList.md)

## Status Information

VHDL Source: [olo_ft_private_cc_toggle](../../src/ft/vhdl/olo_ft_private_cc_toggle.vhd)

**Internal building block.** This entity is the TMR-hardened pulse crossing instantiated by
[olo_ft_cc_simple](./olo_ft_cc_simple.md) (valid path), [olo_ft_cc_status](./olo_ft_cc_status.md) (token feedback path)
and [olo_ft_cc_handshake](./olo_ft_cc_handshake.md) (acknowledge path). It is **not intended for direct end-user
instantiation** and is documented here so the instantiating entities can reference its behavior in one place. For
pulse crossings in user code, use [olo_ft_cc_pulse](./olo_ft_cc_pulse.md).

## Description

The entity transfers single-cycle pulses from one clock domain to another. It works like the pulse crossing of
[olo_base_cc_pulse](../base/olo_base_cc_pulse.md): every input pulse toggles a level, the level is synchronized and
an edge detector in the output clock domain converts every change of the level back into a single-cycle pulse.

In contrast to _olo_base_cc_pulse_, the entity does **not** contain a reset crossing. Both resets must already be
crossed (e.g. the _RstOut_ outputs of [olo_ft_cc_reset](./olo_ft_cc_reset.md)), so both sides are in reset at the same
time. This allows the instantiating entities to share one reset crossing for all their paths.

The pulse frequency must be significantly lower than the slower clock frequency. A spacing of _3 + SyncStages_g_
cycles of the slower clock is sufficient. The entity works for any clock ratio.

## Generics

| Name         | Type     | Default | Description                                            |
| :----------- | :------- | ------- | :----------------------------------------------------- |
| SyncStages_g | positive | 2       | Number of synchronization stages. <br />Range: 2 ... 4 |

## Interfaces

| Name      | In/Out | Length | Default | Description                                                         |
| :-------- | :----- | :----- | ------- | :------------------------------------------------------------------ |
| In_Clk    | in     | 1      | -       | Source clock                                                        |
| In_Rst    | in     | 1      | -       | Reset (high-active, synchronous to _In_Clk_), already crossed       |
| In_Pulse  | in     | 1      | -       | Input pulse (synchronous to _In_Clk_)                               |
| Out_Clk   | in     | 1      | -       | Destination clock                                                   |
| Out_Rst   | in     | 1      | -       | Reset (high-active, synchronous to _Out_Clk_), already crossed      |
| Out_Pulse | out    | 1      | N/A     | Output pulse, exactly one single-cycle pulse per input pulse        |

## Architecture

```text
           In_Clk domain               :                Out_Clk domain
                                       :
In_Pulse --> XOR --> ToggleIn --> olo_ft_cc_bits --> ToggleOut --+-------------> XOR --> Out_Pulse
              ^         |              :          (3 chains +    |               ^
              |         v              :           voter)        v               |
            vote <- ToggleLast[A,B,C]  :                 ToggleOutLast[A,B,C] -> vote
```

- **Toggle register (In_Clk):** three copies. The next value of every copy is computed from the voted value, so an
  upset copy is repaired at the next clock edge.
- **Synchronizer:** [olo_ft_cc_bits](./olo_ft_cc_bits.md) with three independent synchronizer chains and a majority
  voter.
- **Edge detector (Out_Clk):** three copies of the last synchronized toggle value and a voter.

## Fault Tolerance

A single upset of any flip-flop neither produces a spurious output pulse nor loses or duplicates a pulse:

- Upsets of a toggle register copy or an edge detector copy are masked by the voters and repaired at the next clock
  edge.
- Upsets inside [olo_ft_cc_bits](./olo_ft_cc_bits.md) are masked by its voter. The three synchronizer chains may see
  a toggle one clock cycle apart (sampling uncertainty). Because the toggle is a level and not a pulse, the voted
  toggle still changes exactly once per input pulse. A single upset during that window can at most delay the change
  until the last of the three chains sees the toggle, which is within the worst-case latency of a non-hardened
  synchronizer.

### Why Not olo_ft_cc_pulse

[olo_ft_cc_pulse](./olo_ft_cc_pulse.md) implements the SR-latch based synchronizer from Li et al. Using it as the
building block of the multi-bit crossings would change their behavior compared to the _olo_base_ counterparts:

- It limits the clock ratio (approximately _f_out < SyncStages_g x f_in_). The feedback paths of
  _olo_ft_cc_status_ and _olo_ft_cc_handshake_ cross in the opposite direction, so both clocks would have to be within
  a factor of three of each other. The _olo_base_ crossings work for any clock ratio.
- It supports only 3 or 4 sync stages, while the _olo_base_ crossings support 2 to 4.
- Its output pulse is _SyncStages_g - 1_ cycles long and would need an additional edge detector.

The toggle-based crossing has none of these restrictions and keeps the timing of the _olo_base_ crossings.
