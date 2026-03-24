import SwiftUI

struct SegmentEditorView: View {
    @EnvironmentObject var appState: AppState
    let segment: TranscriptionSegment
    let index: Int
    let isActive: Bool
    let totalSegments: Int

    @State private var editingText: String = ""
    @State private var isEditing: Bool = false
    @State private var isHovering: Bool = false
    @FocusState private var textFieldFocused: Bool

    private let fillerWords = ProjectSettings.default.fillerWords

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            textContent
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: isActive ? 2 : 0.5)
        )
        .opacity(segment.isDeleted ? 0.5 : 1.0)
        .onAppear {
            editingText = segment.text
        }
        .onChange(of: segment.text) { _, newValue in
            if !isEditing {
                editingText = newValue
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.seekToSegment(segment)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 6) {
            // セグメント番号
            Text("#\(index + 1)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .leading)

            // タイムスタンプ
            Text(segment.formattedTimeRange)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)

            if containsFillerWord {
                Text("filler")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }

            if segment.isDeleted {
                Text("削除済み")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }

            Spacer()

            // 操作ボタン（ホバーまたはアクティブ時に表示）
            if isHovering || isActive {
                HStack(spacing: 2) {
                    if index > 0 {
                        segmentButton(icon: "arrow.up.to.line", help: "上と結合") {
                            appState.mergeWithPrevious(segmentID: segment.id)
                        }
                    }

                    if index < totalSegments - 1 {
                        segmentButton(icon: "arrow.down.to.line", help: "下と結合") {
                            appState.mergeWithNext(segmentID: segment.id)
                        }
                    }

                    segmentButton(icon: "trash", help: "削除", tint: .red) {
                        appState.deleteSegment(segmentID: segment.id)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    private func segmentButton(icon: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint.opacity(0.8))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Text Content

    private var textContent: some View {
        Group {
            if isEditing {
                editableTextView
            } else {
                displayTextView
            }
        }
    }

    private var displayTextView: some View {
        Text(highlightedText)
            .font(.system(size: 13))
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onTapGesture(count: 2) {
                editingText = segment.text
                isEditing = true
                textFieldFocused = true
            }
    }

    private var editableTextView: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $editingText)
                .font(.system(size: 13))
                .focused($textFieldFocused)
                .frame(minHeight: 44, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("改行位置で分割")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("キャンセル") {
                    editingText = segment.text
                    isEditing = false
                }
                .font(.system(size: 11))
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("確定") {
                    commitEdit()
                }
                .font(.system(size: 11))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        Group {
            if segment.isDeleted {
                Color.red.opacity(0.04)
            } else if isActive {
                Color.accentColor.opacity(0.08)
            } else if isHovering {
                Color(nsColor: .controlBackgroundColor).opacity(0.8)
            } else {
                Color(nsColor: .controlBackgroundColor).opacity(0.5)
            }
        }
    }

    private var borderColor: Color {
        if isActive {
            return .accentColor
        } else if isHovering {
            return Color.secondary.opacity(0.2)
        } else {
            return .clear
        }
    }

    private var containsFillerWord: Bool {
        fillerWords.contains { segment.text.contains($0) }
    }

    private var highlightedText: AttributedString {
        var attributed = AttributedString(segment.text)

        for filler in fillerWords {
            var searchRange = attributed.startIndex..<attributed.endIndex
            while let range = attributed[searchRange].range(of: filler) {
                attributed[range].backgroundColor = .orange.opacity(0.15)
                attributed[range].foregroundColor = .orange
                searchRange = range.upperBound..<attributed.endIndex
            }
        }

        return attributed
    }

    private func commitEdit() {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if lines.count > 1 {
            let joined = lines.joined()
            appState.updateSegmentText(segmentID: segment.id, newText: joined)

            let splitPosition = lines[0].count
            appState.splitSegment(segmentID: segment.id, atTextPosition: splitPosition)
        } else {
            appState.updateSegmentText(segmentID: segment.id, newText: lines.first ?? trimmed)
        }

        isEditing = false
    }
}
