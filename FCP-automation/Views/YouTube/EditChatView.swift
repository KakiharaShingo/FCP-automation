import SwiftUI

struct EditChatView: View {
    @ObservedObject var chatState: EditChatState
    var onSend: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Label("AI編集チャット", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !chatState.messages.isEmpty {
                    Button(action: { chatState.clear() }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("チャット履歴をクリア")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // メッセージ履歴
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chatState.messages.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(chatState.messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                        }

                        if chatState.isProcessing {
                            processingIndicator
                        }

                        if let error = chatState.errorMessage {
                            errorView(error)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: chatState.messages.count) { _ in
                    if let lastMessage = chatState.messages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // 入力欄
            inputBar
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 6) {
            Text("編集内容について指示できます")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("例: 「イントロをもっと短くして」「クリップ2の後半をカットして」")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Message Bubble

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(message.role == "user"
                                  ? Color.accentColor.opacity(0.15)
                                  : Color.secondary.opacity(0.1))
                    )

                Text(formatTimestamp(message.timestamp))
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }

            if message.role == "assistant" { Spacer(minLength: 40) }
        }
    }

    // MARK: - Processing

    private var processingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("AIが編集計画を修正中...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Error

    private func errorView(_ error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(error)
                .font(.system(size: 10))
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(0.08))
        )
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("編集指示を入力...", text: $chatState.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    sendMessage()
                }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !chatState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatState.isProcessing
    }

    private func sendMessage() {
        guard let text = chatState.sendUserMessage() else { return }
        onSend(text)
    }

    // MARK: - Helpers

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
