import ApusKitCore

// Proves `ApusKitCore` is usable with no other ApusKit target imported.
let message = UserMessage(content: [.text("Hello from ApusKitCore")])
print(message.content.count)
