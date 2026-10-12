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

yur

## AI Hook Catalog and local diagnostic dylib workflow

AirCore includes an on-device Foundation Models-assisted catalog scanner for `.txt` and `.md` binary-analysis reports. The catalog itself is bundled as `Sources/HookCatalog.json`; deterministic matching remains available if Apple Foundation Models is unavailable. The model receives only the report text and bundled catalog matches in the local app process; the feature does not upload reports.

From the signing sheet's CFG / Classes & Methods browser, open **AI Hook Catalog · Scan TXT / Markdown** to import a report and review candidate diagnostic templates. Verify any suggested class, selector, method encoding, and address against the actual binary before selecting methods in the Objective-C browser.

The Objective-C method browser can export a generated diagnostic swizzle project ZIP. That ZIP includes `.github/workflows/build-dylib.yml`, which builds an iOS arm64 `GeneratedSwizzle.dylib` and uploads it as a GitHub Actions artifact. Put the ZIP's contents into a GitHub repository and push to `main`/`master`, or manually run the workflow. Download `GeneratedSwizzle-ios-arm64` from the Actions run, then in AirCore's signing sheet choose **Dylib Injection → Add library (.dylib, .framework)** and select the built dylib.

Generated swizzles are intended as diagnostic instrumentation: they log a selected Objective-C call and forward to the captured original implementation. The generator does not automatically alter StoreKit or entitlement outcomes. Generated method signatures currently use placeholders in some cases; verify ABI types against the actual runtime encoding or authoritative headers before loading into a test app. Build success alone does not prove runtime compatibility.
