import ApusKitWireFormat

// Proves `ApusKitWireFormat` is usable with no other ApusKit target
// imported. Feeds a small SSE stream through `SSEParser` in two chunks
// that deliberately split mid-event, then prints the event count.
var parser = SSEParser()
let firstChunk = Array("data: hel".utf8)
let secondChunk = Array("lo\n\ndata: world\n\n".utf8)

var eventCount = 0
do {
  eventCount += try parser.feed(firstChunk).count
  eventCount += try parser.feed(secondChunk).count
} catch {
  print("SSE parse error: \(error)")
}

print("Parsed \(eventCount) SSE event(s)")
