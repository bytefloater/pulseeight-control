# Real device captures

Raw replies from a real NeoMatrix, used by `RealFixtureTests` to prove the models decode what the
hardware really sends (the other fixtures in this target are synthetic, derived from the vendor
library's models).

Record them with the matrix on the network:

```sh
p8ctl --host <matrix-ip> capture PulseEightKit/Tests/PulseEightKitTests/Fixtures/Real
```

Serial numbers and MAC addresses are redacted by default (`--no-redact` keeps them). **Port names are
not redacted**: look through the files before you commit them. The folder may be empty; the tests then
have nothing to check and pass.

File names are the contract: `system-details.json`, `system-features.json`, `port-list.json`,
`port-details-input-<bay>.json`, `port-details-output-<bay>.json`.
