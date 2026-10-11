# CLI Compatibility Harness

This package provides a repository-local compatibility test.

It deliberately does **not** replace macOS's `/System/Library/CoreServices/SystemVersion.plist`,
patch `buddy3`, redirect its filesystem calls, or alter FairPlay/DRM behavior.

The root `SystemVersion.plist` is consumed only by `tools/version_compat_shim.py`.

Supported test profiles in the shim:
- 15.4 -> iOS-15.4
- 16.2 -> iOS-16.2
- 26.0.1 -> iOS-26.0.1

You can also provide `requested_version` when manually dispatching the workflow.

## ADID identity

New installations mint a cryptographically-random `AS-XXXXXX-XX` ADID on first use. The ID is stored in Keychain and is not derived from hardware or display fingerprints.

Administrators can reassign the ADID of their authenticated admin account from Settings → Account. The app calls `account.php` with `action=admin_set_mdid`; the server must atomically update the account ADID and its ADID-based role mapping before returning the canonical ADID. AirShare only changes its local Keychain value after that server response.

See `MDID_IDENTITY.md` for the API contract.

## Local Analysis Center

The AVX512/AirShare analysis stack is local-first and does not require a remote analysis service. The same annotated `UCFunction` feeds the Disassembler Browser, CFG Viewer, Pseudocode Viewer, and Analysis Center.

Analysis Center currently exposes:
- Overview / local analysis statistics
- String annotations
- Resolved symbols/classes/methods
- Function/call inspection
- Basic-block graph edges
- Call/branch/XREF flow
- Hex/memory view of decoded function bytes
- Reversible local NOP/RET patch proposals and patch manifest export
- Original-vs-proposed patch diff
- One-tap navigation back to Disassembler, CFG, and Pseudocode

Patch proposals are deliberately kept as an in-memory/local manifest in this viewer; the source binary is not modified by opening the analysis UI.
