import SwiftUI

/// The ranked microphones, as Settings → Dictation lists them: each one's name, whether
/// it is connected, and the commands that move it or forget it.
///
/// A list inside the form's section, because the form's own rows cannot be dragged:
/// the grouped form draws them itself, and an offscreen render found no table view
/// and no drag types under them. A list is a table that takes reordering drags. Move
/// Up and Move Down do the same from each row's menu.
struct MicrophoneOrderRows: View {
    @Binding var order: [AudioInputDevice]

    /// The microphones connected now.
    let connected: [AudioInputDevice]

    /// The height of the form's own rows, measured in that render, so the list's rows
    /// read as more of them. The list is exactly as tall as its rows and never scrolls.
    private static let rowHeight: CGFloat = 37

    var body: some View {
        if order.isEmpty {
            Text("Indite has not seen a microphone yet.")
                .foregroundStyle(.secondary)
        } else {
            List {
                ForEach(order) { microphone in
                    row(microphone)
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: CGFloat(order.count) * Self.rowHeight)
            .scrollDisabled(true)
        }

        if MicrophoneOrder.slowMicrophoneLeads(order) {
            Text("Wireless microphones, such as AirPods or an iPhone, take a few seconds to start, and Bluetooth ones send phone-call-quality sound, so dictation through them is slower and less accurate. The Mac\u{2019}s microphone usually hears you better.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ microphone: AudioInputDevice) -> some View {
        let isConnected = connected.contains { $0.uid == microphone.uid }
        return HStack(spacing: 8) {
            Text(microphone.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !isConnected {
                Text("Not connected")
                    .foregroundStyle(.secondary)
            }
            Menu {
                commands(for: microphone, isConnected: isConnected)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help("Indite records from the first microphone on this list that can hear you. Drag a microphone to change its place.")
        .contextMenu { commands(for: microphone, isConnected: isConnected) }
    }

    /// Move Up, Move Down, and Remove for a microphone that is not connected. One that
    /// is connected would be added again at once.
    @ViewBuilder
    private func commands(for microphone: AudioInputDevice, isConnected: Bool) -> some View {
        let index = order.firstIndex { $0.uid == microphone.uid }
        Button("Move Up") { move(microphone, by: -1) }
            .disabled(index == order.indices.first)
        Button("Move Down") { move(microphone, by: 1) }
            .disabled(index == order.indices.last)
        if !isConnected {
            Divider()
            Button("Remove") { order.removeAll { $0.uid == microphone.uid } }
        }
    }

    private func move(_ microphone: AudioInputDevice, by step: Int) {
        guard let index = order.firstIndex(where: { $0.uid == microphone.uid }),
              order.indices.contains(index + step) else { return }
        order.swapAt(index, index + step)
    }
}
