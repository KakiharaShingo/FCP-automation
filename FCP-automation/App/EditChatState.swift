import Foundation

struct ChatMessage: Identifiable {
    let id: UUID
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date

    init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

@MainActor
class EditChatState: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isProcessing: Bool = false
    @Published var errorMessage: String?

    func addMessage(role: String, content: String) {
        messages.append(ChatMessage(role: role, content: content))
        errorMessage = nil
    }

    func sendUserMessage() -> String? {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        addMessage(role: "user", content: text)
        inputText = ""
        return text
    }

    func clear() {
        messages.removeAll()
        inputText = ""
        isProcessing = false
        errorMessage = nil
    }
}
