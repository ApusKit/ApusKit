// ApusKitWireFormat
//
// Incremental parse kernels shared by every provider wire format: the
// Server-Sent Events parser and the partial-JSON accumulator used to
// repair streamed tool-call arguments.
//
// PKG-6: this module imports only ApusKitCore. WIRE-1: it is the only
// target where typed `throws` is permitted. WIRE-2: its parsers are the
// nightly fuzz targets, so they are written allocation-conscious and must
// survive a byte-chunk boundary falling anywhere.
