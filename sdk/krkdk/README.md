# krkdk

The SDK for building Kuroko apps in any language (Widget Framework,
"Architecture" and "Bindings"):

- the C ABI of the widget library (Mode A from any language with FFI),
- the Mode B UI host process,
- generated bindings: a C header, then Go and Python.

Not started. It depends on the schema question (one source of truth for the
structures) and on the widget protocol messages (type IDs `0x04xx`).
