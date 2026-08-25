# Open questions

Last reviewed: 2026-08-25
Source of truth: this file

Unresolved decisions that affect implementation. Add here instead of inventing certainty. When a
question is settled, move the answer to the page that owns it (see `owner-page-taxonomy.md`) and
delete the question.

- [ ] **No CI run has been observed yet.** The five workflows exist and the suite is green
      locally, but M0's gate stays un-flipped pending a link to a passing run (PROG-2). Until
      then, no claim about CI behaviour in this brain is verified — only about the workflow files.
- [ ] **Does ApusKitWireFormat stay a separate target?** TRD §1 and PKG-6 give it its own layer
      between Core and Providers, and ERR-1 carves out typed throws only inside it. M1 will show
      whether the split earns its keep or the kernels belong in Providers.
- [ ] **Which HTTP transport ships as the default at M1?** The `NIO` trait pulls
      async-http-client, but the untraited default is presumably URLSession-backed. The seam
      (`Sources/ApusKitProviders/StreamingHTTPTransport.swift`) is declared; no implementation
      exists, and DI-3 forbids `URLSession.shared` inside logic.
- [ ] **How are recorded pi SSE transcripts and pi v3 session files obtained and licensed?**
      TEST-3 requires them as fixtures with a conformance baseline; none exist yet.
- [ ] **What does the M0 gate's CI evidence look like in practice** — which workflow run counts
      as proof of "scripted multi-turn + fake tool round-trip green in CI"? PRD §5 M0 leaves the
      form of the link unspecified.
