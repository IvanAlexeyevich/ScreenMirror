import Foundation

/// Advertise only implemented features: source-clocked, streaming, no seek.
/// No named DLNA codec profile or full DLNA-version compliance is claimed.
enum LiveDLNA {
    static let features = "DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=81000000000000000000000000000000"
}
