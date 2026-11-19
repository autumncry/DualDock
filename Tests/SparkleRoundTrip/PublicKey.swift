import Foundation
import CryptoKit

// The fixture sends a new in-memory seed to this helper and to sign_update
// through stdin. Only the public key is emitted to build the test bundles.
guard let input = readLine(), let seed = Data(base64Encoded: input) else { exit(1) }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
