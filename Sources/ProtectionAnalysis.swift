import SwiftUI
import Foundation

/// A concrete, address-backed observation from the analyzed Mach-O.
/// `confidence` describes evidence strength, not whether the app is vulnerable.
nonisolated struct ProtectionFinding: Identifiable, Sendable {
    let id: String
    let category: String
    let title: String
    let confidence: String
    let location: String
    let evidence: [String]
    let note: String
}

nonisolated enum ProtectionAnalysis {
    private typealias Profile = ProtectionProfile

    private struct StringHit {
        let value: String
        let section: String
        let va: UInt64
        let fileOffset: Int
    }

    private struct CallHit {
        let api: String
        let callVA: UInt64
        let functionName: String
        let functionVA: UInt64
    }

    private static let profiles: [Profile] = ProtectionProfiles.all

    static func scan(ipaURL: URL) async -> [ProtectionFinding] {
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else { return [] }
        let thin = ctx.thin
        let symbols = MachOTools.symbolMap(in: thin)
        let imports = MachOTools.importStubMap(in: thin)
        let strings = collectStrings(thin: thin, sections: ctx.sections)
        let calls = collectImportedCalls(thin: thin, sections: ctx.sections, imports: imports,
                                         starts: MachOTools.functionStarts(in: thin), symbols: symbols)
        var output: [ProtectionFinding] = []
        var seen = Set<String>()

        for profile in profiles {
            let matchingCalls = calls.filter { call in
                let name = call.api.lowercased()
                return profile.importTerms.contains { name.contains($0.lowercased()) }
            }
            for call in matchingCalls.prefix(80) {
                let key = "\(profile.category)|call|\(call.callVA)|\(call.api)"
                guard seen.insert(key).inserted else { continue }
                output.append(ProtectionFinding(
                    id: key, category: profile.category, title: profile.title,
                    confidence: "Resolved imported call",
                    location: String(format: "call 0x%llx · %@ 0x%llx", call.callVA, call.functionName, call.functionVA),
                    evidence: ["API: \(call.api)", String(format: "Call-site VA: 0x%llx", call.callVA),
                              String(format: "Containing function: %@ (0x%llx)", call.functionName, call.functionVA)],
                    note: profile.note))
            }

            let matchingStrings = strings.filter { hit in
                let value = hit.value.lowercased()
                return profile.stringTerms.contains { value.contains($0.lowercased()) }
            }
            for hit in matchingStrings.prefix(80) {
                let key = "\(profile.category)|str|\(hit.fileOffset)|\(hit.value)"
                guard seen.insert(key).inserted else { continue }
                output.append(ProtectionFinding(
                    id: key, category: profile.category, title: profile.title,
                    confidence: "Address-backed string indicator",
                    location: String(format: "%@ VA 0x%llx · file offset 0x%x", hit.section, hit.va, hit.fileOffset),
                    evidence: [hit.value, "Section: \(hit.section)", String(format: "String VA: 0x%llx", hit.va),
                              String(format: "Thin-slice file offset: 0x%x", hit.fileOffset)],
                    note: profile.note))
            }
        }
        return output.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.location < $1.location
        }
    }

    private static func collectStrings(thin: Data, sections: [MachOTools.Section]) -> [StringHit] {
        let wanted: Set<String> = ["__cstring", "__objc_methname", "__objc_classname", "__objc_methtype"]
        var hits: [StringHit] = []
        for section in sections where wanted.contains(section.name) {
            guard section.offset <= UInt64(thin.count) else { continue }
            let start = Int(section.offset)
            guard section.size > 0, section.size <= UInt64(thin.count - start) else { continue }
            let size = Int(section.size)
            guard size > 0, start < thin.count else { continue }
            let end = start + size
            var cursor = start
            while cursor < end {
                let stringStart = cursor
                while cursor < end, thin[thin.startIndex + cursor] != 0 { cursor += 1 }
                let length = cursor - stringStart
                if length >= 4, length <= 4096,
                   let value = String(data: thin.subdata(in: stringStart..<cursor), encoding: .utf8),
                   value.unicodeScalars.allSatisfy({ !$0.properties.isControl }) {
                    hits.append(StringHit(value: value, section: section.name,
                                          va: section.addr + UInt64(stringStart - start), fileOffset: stringStart))
                }
                cursor += 1
            }
        }
        return hits
    }

    /// Finds actual ARM64 BL instructions whose computed target equals a real
    /// imported stub address. No target is inferred from an API-name string.
    private static func collectImportedCalls(thin: Data, sections: [MachOTools.Section],
                                             imports: [UInt64: String], starts: [UInt64],
                                             symbols: [UInt64: String]) -> [CallHit] {
        guard !imports.isEmpty, let text = MachOTools.textSection(sections, in: thin) else { return [] }
        let orderedStarts = starts.sorted()
        let textData = text.data
        var result: [CallHit] = []
        textData.withUnsafeBytes { raw in
            let count = raw.count / 4
            for i in 0..<count {
                let word = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                guard (word & 0xFC00_0000) == 0x9400_0000 else { continue } // BL imm26
                let imm = Int64(AVXDisassembler.signExtend(UInt64(word & 0x03FF_FFFF), 26)) * 4
                let site = text.vmaddr + UInt64(i * 4)
                let targetSigned = Int64(bitPattern: site) + imm
                guard targetSigned >= 0, let api = imports[UInt64(targetSigned)] else { continue }
                let fn = orderedStarts.last(where: { $0 <= site })
                let name = fn.flatMap { symbols[$0] }.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
                    ?? fn.map { String(format: "sub_%llx", $0) } ?? "unknown function"
                result.append(CallHit(api: api, callVA: site, functionName: name, functionVA: fn ?? site))
            }
        }
        return result
    }
}

struct ProtectionAnalysisSheet: View {
    let ipaURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var findings: [ProtectionFinding] = []
    @State private var isLoading = true
    @State private var selectedCategory = "All"
    @State private var query = ""
    @State private var impactFinding: ProtectionFinding?
    @State private var showManualPatchWorkbench = false

    private var categories: [String] { ["All"] + Array(Set(findings.map(\.category))).sorted() }
    private var filtered: [ProtectionFinding] {
        findings.filter { (selectedCategory == "All" || $0.category == selectedCategory) &&
            (query.isEmpty || ($0.title + " " + $0.location + " " + $0.evidence.joined(separator: " ")).localizedCaseInsensitiveContains(query)) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) { ProgressView(); Text("Analyzing Mach-O evidence…").font(.subheadline).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if findings.isEmpty {
                    ContentUnavailableView("No matching indicators", systemImage: "checkmark.shield",
                        description: Text("No matching imported calls or strings were found in the main ARM64 binary. Indirect calls, stripped metadata, and embedded frameworks may require separate analysis."))
                } else {
                    List {
                        Section {
                            Text("Address-backed static-analysis leads. Imported calls are matched to real ARM64 BL targets; strings include section addresses and file offsets. These findings do not prove runtime behavior and no patches are applied.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Picker("Category", selection: $selectedCategory) {
                                ForEach(categories, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            TextField("Search findings", text: $query)
                            Button { showManualPatchWorkbench = true } label: {
                                Label("Open Manual Patch Generator", systemImage: "wrench.and.screwdriver")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        ForEach(filtered) { finding in
                            Section { VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(finding.title).font(.headline)
                                    Spacer(minLength: 8)
                                    Text(finding.confidence).font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                                }
                                Text(finding.location).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                ForEach(finding.evidence, id: \.self) { item in
                                    Text(item).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Text(finding.note).font(.caption).foregroundStyle(.secondary)
                                Button {
                                    impactFinding = finding
                                } label: {
                                    Label("Preview change & repercussions", systemImage: "arrow.left.arrow.right.circle")
                                        .font(.subheadline.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .padding(.top, 2)
                            }.padding(.vertical, 4) } header: { Text(finding.category) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black)
            .navigationTitle("Protection Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .sheet(item: $impactFinding) { finding in
                PatchImpactPreviewSheet(finding: finding, ipaURL: ipaURL)
            }
            .sheet(isPresented: $showManualPatchWorkbench) {
                ManualPatchWorkbench(findings: findings, ipaURL: ipaURL)
            }
            .task {
                findings = await ProtectionAnalysis.scan(ipaURL: ipaURL)
                isLoading = false
            }
        }
        .preferredColorScheme(.dark)
    }
}
