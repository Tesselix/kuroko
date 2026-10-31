# krksim

The Kuroko device simulator: virtual Wi-Fi networks, wired LAN cards and
Bluetooth devices on the test VM, so Kuroko's device-management tools can be
tested against the real kernel, NetworkManager and BlueZ.

Not started. Planned pieces: the `krksimd` daemon (owns the virtual devices),
the `krksim` CLI, a GUI built with the SDK, Bluetooth peer devices, and
scenario files.

Depends on `sdk/` only (the record format, and the widget library for the
GUI); never on `de/`.
