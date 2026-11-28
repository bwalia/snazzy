import Interview
import SwiftUI

/// Every finished interview for one role, side by side, for the hiring manager.
/// Sorted by name (or date) by default; sorting by a competency's level is a choice the
/// reviewer makes. There is no overall score: people compare the evidence, then decide.
struct CompareCandidatesView: View {
    @Environment(AppModel.self) private var model
    let kit: RoleKit
    let comparison: RoleComparison
    let onOpen: (UUID) -> Void

    @State private var sort: RoleComparison.Sort = .name

    var body: some View {
        let rows = comparison.sorted(by: sort)
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Compare: \(kit.title)").font(.title.bold())
                Text("Your levels where you've set them; otherwise the AI's suggestion, marked \"(AI)\". Open a candidate to read the evidence before you decide.")
                    .foregroundStyle(.secondary)
                HStack {
                    Picker("Order", selection: $sort) {
                        Text("Name").tag(RoleComparison.Sort.name)
                        Text("Most recent").tag(RoleComparison.Sort.date)
                        Divider()
                        ForEach(comparison.competencies) { c in
                            Text("Level: \(c.name)").tag(RoleComparison.Sort.level(c.id))
                        }
                    }
                    .frame(maxWidth: 320)
                    Spacer()
                    Button("Save as CSV…") { model.interviews.saveComparisonCSV(comparison, order: rows, title: kit.title) }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Candidate").bold()
                        Text("Status").bold()
                        ForEach(comparison.competencies) { c in
                            Text(c.name).bold().lineLimit(2).frame(maxWidth: 140, alignment: .leading).help("\(c.weight)%: \(c.description)")
                        }
                        Text("Flags").bold()
                    }
                    Divider()
                    ForEach(rows) { row in
                        GridRow {
                            Button {
                                onOpen(row.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.candidate)
                                    Text("\(row.date.formatted(date: .abbreviated, time: .omitted)) · v\(row.kitVersion)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.link)
                            .help("Open the interview")
                            Text(row.status).foregroundStyle(row.decision == nil ? .orange : .primary)
                            ForEach(comparison.competencies) { c in
                                let cell = row.cells[c.id] ?? LevelCell(level: nil, source: .none)
                                Text(cell.text)
                                    .foregroundStyle(cell.source == .reviewer ? .primary : .secondary)
                                    .italic(cell.source == .ai)
                            }
                            Text(row.flags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                }
                if rows.contains(where: { $0.kitVersion != kit.version }) {
                    Text("Some interviews used an earlier version of this kit; their questions may differ.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
