import SwiftUI
import PetalCore

/// Recursive notebook sidebar (spec §Session 5 Part A.1), bound to a shared
/// `LibraryViewModel`. Notebook rows and paper cards elsewhere in the app share
/// one drag payload convention — a `String` of the form `"paper:<id>"` or
/// `"notebook:<id>"` — which the drop targets below parse.
struct NotebookTreeView: View {
    @ObservedObject var viewModel: LibraryViewModel

    @State private var activeDialog: ActiveDialog?
    @State private var dialogText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.childNotebooks(of: nil)) { notebook in
                            NotebookRow(
                                notebook: notebook,
                                viewModel: viewModel,
                                activeDialog: $activeDialog,
                                dialogText: $dialogText
                            )
                        }

                        rootDropZone
                    }
                    .frame(
                        minHeight: max(0, geometry.size.height - 8),
                        alignment: .top
                    )
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                }
            }

            Divider()

            Button {
                dialogText = ""
                activeDialog = .createRoot
            } label: {
                Label("New Notebook", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .alert(
            dialogTitle,
            isPresented: isDialogPresented,
            presenting: activeDialog,
            actions: { dialog in dialogActions(for: dialog) },
            message: { dialog in
                if let message = dialogMessage(for: dialog) {
                    Text(message)
                }
            }
        )
    }

    /// A distinct target below the notebook rows lets a nested notebook be
    /// moved back to the root. Keeping the target on this flexible open-space
    /// view (rather than the enclosing scroll view) leaves row drops handled
    /// by each `NotebookRow`.
    private var rootDropZone: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                var handledDrop = false
                for item in items {
                    if let notebookId = item.strippingDragPrefix("notebook:") {
                        viewModel.moveNotebook(id: notebookId, toParent: nil)
                        handledDrop = true
                    }
                }
                return handledDrop
            }
    }

    // MARK: - Shared alert

    private var isDialogPresented: Binding<Bool> {
        Binding(
            get: { activeDialog != nil },
            set: { presented in if !presented { activeDialog = nil } }
        )
    }

    private var dialogTitle: String {
        switch activeDialog {
        case .createRoot, .createSubfolder:
            return "New Notebook"
        case .rename:
            return "Rename Notebook"
        case .deleteConfirm:
            return "Delete Notebook?"
        case nil:
            return ""
        }
    }

    private func dialogMessage(for dialog: ActiveDialog) -> String? {
        switch dialog {
        case .deleteConfirm:
            return "This will delete any sub-notebooks and move their papers to Unfiled."
        case .createRoot, .createSubfolder, .rename:
            return nil
        }
    }

    @ViewBuilder
    private func dialogActions(for dialog: ActiveDialog) -> some View {
        switch dialog {
        case .createRoot:
            TextField("Name", text: $dialogText)
            Button("Create") {
                commitCreate(parentId: nil)
            }
            Button("Cancel", role: .cancel) { activeDialog = nil }

        case .createSubfolder(let parentId):
            TextField("Name", text: $dialogText)
            Button("Create") {
                commitCreate(parentId: parentId)
            }
            Button("Cancel", role: .cancel) { activeDialog = nil }

        case .rename(let id, _):
            TextField("Name", text: $dialogText)
            Button("Rename") {
                let name = dialogText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    viewModel.renameNotebook(id: id, to: name)
                }
                activeDialog = nil
            }
            Button("Cancel", role: .cancel) { activeDialog = nil }

        case .deleteConfirm(let id):
            Button("Delete", role: .destructive) {
                viewModel.deleteNotebook(id: id)
                activeDialog = nil
            }
            Button("Cancel", role: .cancel) { activeDialog = nil }
        }
    }

    private func commitCreate(parentId: String?) {
        let name = dialogText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            viewModel.createNotebook(name: name, parentId: parentId)
        }
        activeDialog = nil
    }
}

/// Which dialog (if any) is currently driving `NotebookTreeView`'s single shared
/// `.alert`, and the data it needs (a target notebook id and/or prefilled text).
/// Consolidating every create/rename/delete flow into one enum avoids stacking
/// multiple `.alert` modifiers across the tree.
private enum ActiveDialog: Identifiable {
    case createRoot
    case createSubfolder(parentId: String)
    case rename(id: String, currentName: String)
    case deleteConfirm(id: String)

    var id: String {
        switch self {
        case .createRoot:
            return "createRoot"
        case .createSubfolder(let parentId):
            return "createSubfolder:\(parentId)"
        case .rename(let id, _):
            return "rename:\(id)"
        case .deleteConfirm(let id):
            return "deleteConfirm:\(id)"
        }
    }
}

/// One row of the recursive notebook tree. A notebook with children renders as
/// a `DisclosureGroup` that recurses into `NotebookRow` for each child; a leaf
/// notebook renders as a plain selectable row. Every row is both a drag source
/// (`"notebook:<id>"`) and a drop destination that accepts dropped papers and
/// other notebooks (re-parenting them).
private struct NotebookRow: View {
    let notebook: Notebook
    @ObservedObject var viewModel: LibraryViewModel
    @Binding var activeDialog: ActiveDialog?
    @Binding var dialogText: String

    @State private var isExpanded = true

    private var children: [Notebook] {
        viewModel.childNotebooks(of: notebook.id)
    }

    private var isSelected: Bool {
        viewModel.selection == .notebook(notebook.id)
    }

    var body: some View {
        Group {
            if children.isEmpty {
                rowLabel
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children) { child in
                        NotebookRow(
                            notebook: child,
                            viewModel: viewModel,
                            activeDialog: $activeDialog,
                            dialogText: $dialogText
                        )
                    }
                } label: {
                    rowLabel
                }
            }
        }
        .draggable("notebook:\(notebook.id)")
        .dropDestination(for: String.self) { items, _ in
            handleDrop(items)
            return true
        }
        .contextMenu {
            Button("New Subfolder") {
                dialogText = ""
                activeDialog = .createSubfolder(parentId: notebook.id)
            }
            Button("Rename") {
                dialogText = notebook.name
                activeDialog = .rename(id: notebook.id, currentName: notebook.name)
            }
            Button("Delete", role: .destructive) {
                if viewModel.notebookContainsPapers(id: notebook.id) {
                    activeDialog = .deleteConfirm(id: notebook.id)
                } else {
                    viewModel.deleteNotebook(id: notebook.id)
                }
            }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(notebook.name)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selection = .notebook(notebook.id)
        }
    }

    /// Parses each dropped payload per the app-wide drag convention and routes
    /// it to the matching `LibraryViewModel` mutation. A notebook dropped onto
    /// itself is ignored.
    private func handleDrop(_ items: [String]) {
        for item in items {
            if let paperId = item.strippingDragPrefix("paper:") {
                viewModel.movePaper(paperId: paperId, toNotebook: notebook.id)
            } else if let notebookId = item.strippingDragPrefix("notebook:"), notebookId != notebook.id {
                viewModel.moveNotebook(id: notebookId, toParent: notebook.id)
            }
        }
    }
}

private extension String {
    /// Returns the remainder of the string if it starts with `prefix`, else
    /// `nil`. Used to parse the app-wide drag payload convention
    /// (`"paper:<id>"` / `"notebook:<id>"`).
    func strippingDragPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
