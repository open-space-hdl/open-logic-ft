<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_sync

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/coverage/olo_ft_sync.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/branches/olo_ft_sync.json?cacheSeconds=0)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_sync.json?cacheSeconds=0)

VHDL Source: [olo_ft_sync](../../src/ft/vhdl/olo_ft_sync.vhd)

## Description

This component is a **TMR-hardened synchronizer for asynchronous input signals** (external inputs, status signals of
hard IP without a clock). A single-event upset (SEU) on any flip-flop of the synchronizer does not change the output.

It is the fault-tolerant counterpart of [olo_intf_sync](../intf/olo_intf_sync.md) with the same interface and the same
behavior. Like _olo_intf_sync_, it synchronizes each bit separately: it is meant for individual bits, not for
multi-bit values that must be consistent (use the _olo_ft_cc_\<...\>_ clock crossings for signals that come from a
known clock domain, e.g. [olo_ft_cc_bits](./olo_ft_cc_bits.md) or [olo_ft_cc_status](./olo_ft_cc_status.md)).

## Generics

| Name         | Type      | Default | Description                                                  |
| :----------- | :-------- | ------- | :----------------------------------------------------------- |
| Width_g      | positive  | 1       | Number of bits to synchronize                                |
| RstLevel_g   | std_logic | '0'     | Reset state of the synchronizer registers                    |
| SyncStages_g | positive  | 2       | Number of synchronization stages. <br />Range: 2 ... 4       |

## Interfaces

| Name      | In/Out | Length    | Default | Description                                     |
| :-------- | :----- | :-------- | ------- | :---------------------------------------------- |
| Clk       | in     | 1         | -       | Clock                                           |
| Rst       | in     | 1         | '0'     | Reset input (high-active, synchronous to _Clk_) |
| DataAsync | in     | _Width_g_ | -       | Asynchronous input signals                      |
| DataSync  | out    | _Width_g_ | -       | Synchronized output signals                     |

## Architecture

For each bit, the design triplicates the synchronizer chain of _olo_intf_sync_ and combines the three outputs with a
majority voter:

```text
DataAsync[i] --+--> Reg0_A --> RegN_A(..) --.
               |                             \
               +--> Reg0_B --> RegN_B(..) ----+--> Voter --> DataSync[i]
               |                             /
               +--> Reg0_C --> RegN_C(..) --'
```

An upset in one chain is shifted out after _SyncStages_g_ clock cycles and masked by the voter in the meantime.

### Limitations

- The three chains sample the asynchronous input independently. Around a change of the input, the chains may resolve
  the new value one clock cycle apart; the voted output follows the second chain. An upset of one of the two agreeing
  chains in exactly this cycle shifts the voted change by one clock cycle, which is within the normal latency
  variation of a synchronizer. Input values that are shorter than one clock period plus the skew between the chains
  can be lost in this case (see the [stability requirement](./olo_ft_cc_bits.md#stability-requirement) of
  _olo_ft_cc_bits_ and the analysis in [1]).
- TMR masks one upset per bit and clock cycle. Two upsets in different chains of the same bit within _SyncStages_g_
  clock cycles are not masked.
- The voters are not triplicated. The design targets upsets of storage elements (SEU), not single-event transients in
  combinational logic.

### Synthesis Attributes

- **`syn_radhardlevel = "none"`** at the architecture level prevents tools like Synplify (Microchip Libero) from
  triplicating the already-triplicated registers.
- All synchronizer attributes of _olo_intf_sync_ (`async_reg`, `dont_merge`, `preserve`, `syn_preserve`, `syn_keep`,
  `shreg_extract`, `syn_srlstyle`) plus `dont_touch` on every copy prevent the synthesis tool from merging the three
  chains (which would defeat the TMR).

## Constraints

The same constraints as for _olo_intf_sync_ apply: the path from the input to the first synchronizer stage (_Reg0_)
must be shorter than one clock period (`set_max_delay -datapath_only`).

The register names match _olo_intf_sync_, so in _AMD Vivado_ its scoped constraint file can be used for inputs that
come from device pins: `read_xdc -ref olo_ft_sync <path>/src/intf/tcl/olo_intf_sync.tcl`. For signals that come from
hard IP inside the device (e.g. transceiver status), constrain the paths to _Reg0_ manually.

## References

[1] Y. Li, B. Nelson, and M. Wirthlin, "Synchronization Techniques for Crossing Multiple Clock
Domains in FPGA-Based TMR Circuits," IEEE Transactions on Nuclear Science, vol. 57, no. 6,
pp. 3506-3514, Dec. 2010. DOI: 10.1109/TNS.2010.2086075
