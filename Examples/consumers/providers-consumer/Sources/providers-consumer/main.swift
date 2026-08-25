import ApusKitProviders

// Proves `ApusKitProviders` is usable with no other ApusKit target
// imported. `scripts: [[]]` needs no `StreamEvent` spelled out — its
// element type is inferred from `ScriptedProvider.init`'s own signature.
var registry = ProviderRegistry()
registry.register(ScriptedProvider(id: .scripted, scripts: [[]]))
print(registry.implementation(id: .scripted)?.id.rawValue ?? "none")
