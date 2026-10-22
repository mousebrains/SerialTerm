# Contributing

Issues and pull requests are welcome.

- Read [docs/development.md](docs/development.md) for building, testing and conventions.
- Include tests with changes. For file-transfer changes, run the lrzsz interop suites
  (`brew install lrzsz`, then `swift test`).
- For a transfer problem with a particular device, attach the protocol trace
  (Transfer ▸ Open Last Transfer Trace). If possible, use the "Frames + raw bytes" level and give
  the device's make, model and firmware.
