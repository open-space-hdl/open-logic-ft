<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_cc_bits

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_cc_bits.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_cc_bits.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_cc_bits.json?cacheSeconds=0)

VHDL Source: [olo_ft_cc_bits](../../src/ft/vhdl/olo_ft_cc_bits.vhd)

## Description

This component is a **TMR-hardened multi-bit clock domain crossing** for level signals. It uses three independent
synchronizer chains and a majority voter per bit. A single SEU on any flip-flop inside the crossing is masked as long
as every input value stays stable for at least two periods of the slower clock (see
[Stability Requirement](#stability-requirement); Gray-coded values do not need this).

It is the fault-tolerant counterpart to [olo_base_cc_bits](../base/olo_base_cc_bits.md) with an
identical interface. Use it for level signals (control bits, status flags, Gray-coded FIFO pointers, etc.) in
radiation-hardened designs. For pulse-based CDC, consider [olo_ft_cc_pulse](./olo_ft_cc_pulse.md) instead.

## Generics

| Name         | Type     | Default | Description                                                  |
| :----------- | :------- | :------ | :----------------------------------------------------------- |
| Width_g      | positive | 1       | Number of parallel bits                                      |
| SyncStages_g | positive | 2       | Number of receiver-domain sync stages per chain (range 2-4). Same meaning as in `olo_base_cc_bits`. |

## Interfaces

| Name     | In/Out | Length    | Default | Description                                               |
| :------- | :----- | :-------- | :------ | :-------------------------------------------------------- |
| In_Clk   | in     | 1         | -       | Sender's clock                                            |
| In_Rst   | in     | 1         | '0'     | Reset in sender's domain (active high)                    |
| In_Data  | in     | _Width_g_ | -       | Input data (level signal)                                 |
| Out_Clk  | in     | 1         | -       | Receiver's clock                                          |
| Out_Rst  | in     | 1         | '0'     | Reset in receiver's domain (active high)                  |
| Out_Data | out    | _Width_g_ | N/A     | Synchronized output data (level signal)                   |

## Detailed Description

### Architecture

For each bit, the design triplicates the synchronizer chain of
[olo_base_cc_bits](../base/olo_base_cc_bits.md) and combines the outputs of the three chains with a majority voter
(register TMR: the registers are triplicated, the voter is not):

```text
                 In_Clk         :             Out_Clk
In_Data --+--> RegIn_A --------:--> Reg0_A --> RegN_A(..) --+
          +--> RegIn_B --------:--> Reg0_B --> RegN_B(..) --+--> Voter --> Out_Data
          +--> RegIn_C --------:--> Reg0_C --> RegN_C(..) --+
```

- Each TMR copy (A, B, C) has its own sender-side register (_RegIn_) clocked by _In_Clk_ and its own chain of
  _SyncStages_g_ receiver-side registers (_Reg0_, _RegN_) clocked by _Out_Clk_.
- The three chains are independent. No voter is placed between the synchronizer stages, so every chain has the same
  resolution time (and metastability MTBF) as the chain of _olo_base_cc_bits_.
- One majority voter per bit, `(A and B) or (B and C) or (A and C)`, follows the last stage. _Out_Data_ is the
  combinational voter output; use it synchronously to _Out_Clk_ like any other register output.

### TMR and Clock Crossings

There is no general industry standard for clock crossings in TMR designs. The literature agrees on one rule: **never
place voters between the stages of a synchronizer**. A voter there adds delay to the path whose slack determines the
metastability MTBF, and the three flip-flops of the first stage sample the same asynchronous signal independently.
NASA/GSFC [2] names two correct implementations:

| Variant | Synchronizer | Upset of a synchronizer flip-flop |
| --- | --- | --- |
| a) No TMR in the synchronizer | One chain, not triplicated (the surrounding logic may be triplicated) | Not masked: wrong output value for one clock cycle |
| b) Three independent chains, voters after the last stage | This entity ([1] Fig. 12, [2], [3]) | Masked |

Variant a) is what Synplify (Microchip Libero) intends for clock crossings it recognizes as safe: with
`syn_radhardlevel = "tmr"` it does not triplicate the driver and synchronizer flip-flops of a safe CDC path. It does
not recognize the synchronizer of _olo_base_cc_bits_ as safe, though (the `syn_keep` attributes and the synchronous
reset place logic between the stages from the point of view of the tool). Synplify then applies local TMR to all
registers of _olo_base_cc_bits_, including voters between _Reg0_ and _RegN_. This was observed with Libero SoC 2025.2
(Synplify Pro W-2025.03M-SP1-1) for PolarFire SoC.

Whether variant a) is sufficient depends on the signal. A wrong value for one cycle is harmless for a quasi-static
level, but on a toggle, handshake or reset crossing it creates spurious or lost events. Variant b) masks the upset.

### Stability Requirement

The three chains sample the input independently. Because of the skew between the three paths and the randomness of
sampling an asynchronous signal, they may take a change of the input one _Out_Clk_ cycle apart. During that cycle,
two chains agree and one does not, so an upset of one of the two agreeing chains decides the vote [1]:

- For a value that stays at the input, this only shifts the voted change by one cycle, which is within the normal
  latency variation of any synchronizer.
- For a value that is shorter than this window, the upset can remove it from the voted output.

A single upset is therefore masked under the following condition: every value at the input, including every gap
between two pulses, stays stable for at least one _Out_Clk_ period plus the maximum skew between the three chains
[1]. With the constraints of the [clock-crossing principles](../base/clock_crossing_principles.md) (maximum delay of
one period of the faster clock on all paths of all three chains), **two periods of the slower clock** always fulfill
this condition.

If the condition is not fulfilled, the entity still works like _olo_base_cc_bits_ (values shorter than one
_Out_Clk_ period may be lost in both cases); only an upset that falls into the disagreement window is not masked.

- The toggle levels of [olo_ft_cc_pulse](./olo_ft_cc_pulse.md), [olo_ft_cc_simple](./olo_ft_cc_simple.md),
  [olo_ft_cc_status](./olo_ft_cc_status.md) and [olo_ft_cc_handshake](./olo_ft_cc_handshake.md) and the acknowledge
  levels of [olo_ft_cc_reset](./olo_ft_cc_reset.md) fulfill the condition by construction.
- **Gray-coded** values (e.g. FIFO pointers) do not need it: at every sampling edge at most one bit is in transition,
  so a single upset can only select the old or the new value of that bit, and the voted output is always a valid
  value. See [olo_ft_fifo_async](./olo_ft_fifo_async.md#why-per-bit-voting-is-safe-for-gray-coded-fifo-pointers).
- For **binary-coded** multi-bit values, the same restrictions as for _olo_base_cc_bits_ apply (bits may arrive in
  different cycles).

### Fault Model

- One upset per bit within _SyncStages_g_ + 1 clock cycles is masked (under the condition above). Two upsets in
  different copies of the same bit within this time are not masked.
- The voters are not triplicated. The design targets upsets of storage elements (SEU), not single-event transients
  in combinational logic.
- Flip-flops of different copies that are placed next to each other can be hit by the same particle (multiple-cell
  upset). This is outside the scope of the entity.

### Synthesis Attributes

- **`syn_radhardlevel = "none"`** at the architecture level. Tells tools like Synplify (Microchip Libero) not to apply
  their own TMR to the manually triplicated registers. Without it, Synplify would insert voters between the
  synchronizer stages of each chain.
- **All standard CDC attributes** from _olo_base_cc_bits_ (`async_reg`, `dont_merge`, `preserve`, `syn_preserve`,
  `syn_keep`, `shreg_extract`, `syn_srlstyle`) on each triplicated register. They prevent the synthesis tool from
  merging the three copies back into a single chain (which would defeat the TMR).

The entity requires three times the flip-flops of _olo_base_cc_bits_ plus one voter per bit.

## Constraints

The same constraints as for _olo_base_cc_bits_ apply, see
[clock-crossing principles](../base/clock_crossing_principles.md). They must cover the paths of all three chains,
because the skew between the chains is part of the stability requirement above.

Note that the scoped constraints for automatic constraining in _AMD Vivado_ are only provided for the _olo_base_
clock crossings. Constrain the clock crossings of _olo_ft_ entities manually.

## Relationship to Other Components

- [olo_base_cc_bits](../base/olo_base_cc_bits.md): the non-TMR version with the same interface.
- [olo_ft_cc_pulse](./olo_ft_cc_pulse.md): TMR-hardened CDC for pulses (toggle crossing over _olo_ft_cc_bits_). Use it
  when the input is an event/pulse that must arrive exactly once at the receiver.
- [olo_ft_fifo_async](./olo_ft_fifo_async.md): uses _olo_ft_cc_bits_ for the Gray-coded pointer crossings.

## References

[1] Y. Li, B. Nelson, and M. Wirthlin, "Synchronization Techniques for Crossing Multiple Clock
Domains in FPGA-Based TMR Circuits," IEEE Transactions on Nuclear Science, vol. 57, no. 6,
pp. 3506-3514, Dec. 2010. DOI: 10.1109/TNS.2010.2086075

[2] M. Berg and K. LaBel, "Revisions to Conventional Clock Domain Crossing Methodologies in Triple Modular Redundant
Circuits," Hardened Electronics and Radiation Technology Conference (HEART), Apr. 2018, NASA/GSFC.
[Slides](https://nepp.nasa.gov/files/30409/NEPP-CP-2018-Berg-Presentation-HEART-TN65900-NEPPweb-reuse-TN54872.pdf)

[3] Y. Fan and Z. Deng, "Design and verification for CDC synchronization based on TMR," IEICE
Electronics Express, vol. 17, no. 21, pp. 1-6, 2020. DOI: 10.1587/elex.17.20200287
