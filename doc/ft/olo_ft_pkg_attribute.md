<img src="../Logo.png" alt="Logo" width="400">

# olo_ft_pkg_attribute

[Back to **Entity List**](../EntityList.md)

## Status Information

![Endpoint Badge](<https://img.shields.io/badge/statement coverage-No Code-green?cacheSeconds=0>)
![Endpoint Badge](<https://img.shields.io/badge/statement coverage-No Code-green?cacheSeconds=0>)
![Endpoint Badge](https://img.shields.io/endpoint?url=https://storage.googleapis.com/open-logic-badges/issues/olo_ft_pkg_attribute.json?cacheSeconds=0)

VHDL Source: [olo_ft_pkg_attribute](../../src/ft/vhdl/olo_ft_pkg_attribute.vhd)

## Description

This package contains synthesis attributes specific to fault-tolerant (TMR) designs, currently
the control of vendor-provided TMR insertion (e.g. `syn_radhardlevel` for Synplify). General
purpose synthesis attributes are kept in
[olo_base_pkg_attribute](../base/olo_base_pkg_attribute.md).

Like `olo_base_pkg_attribute`, **this package is meant for internal use** mainly and it is
**undocumented**.

Users are still free to use the package but no support will be given. If you decide to do so,
orient yourself on code samples (e.g. in [olo_ft_cc_bits](./olo_ft_cc_bits.md) or
[olo_ft_cc_pulse](./olo_ft_cc_pulse.md)) and on the comments within the source code of the
package.
