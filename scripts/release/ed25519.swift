// Ed25519 signing for update files, in the format Sparkle (macOS) and NetSparkle (Windows) check: a pure
// Ed25519 signature over the file's bytes, base64 encoded; public keys are the raw 32 bytes, base64 encoded.
//
//     swift scripts/release/ed25519.swift generate
//     ED25519_PRIVATE_KEY=... swift scripts/release/ed25519.swift public
//     ED25519_PRIVATE_KEY=... swift scripts/release/ed25519.swift sign  <file>
//     swift scripts/release/ed25519.swift verify <file> <public-key> <signature>
//
// The private key is read from $ED25519_PRIVATE_KEY and never from an argument, so it can't show up in a
// process list or a CI log. It may be the 32-byte seed or the 64 bytes (seed + public key) that Sparkle's
// `generate_keys -x` exports, both base64. macOS only (CryptoKit), which is where releases are signed.

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = ProcessInfo.processInfo.environment["ED25519_PRIVATE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
    else { fail("Set ED25519_PRIVATE_KEY (base64) in the environment.") }
    guard let bytes = Data(base64Encoded: text) else { fail("ED25519_PRIVATE_KEY isn't valid base64.") }
    guard bytes.count == 32 || bytes.count == 64 else { fail("ED25519_PRIVATE_KEY must be 32 or 64 bytes, not \(bytes.count).") }
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes.prefix(32)) else { fail("That isn't a usable Ed25519 key.") }
    if bytes.count == 64, Data(bytes.suffix(32)) != key.publicKey.rawRepresentation {
        fail("The key's public half doesn't match its private half: it is corrupt or mismatched.")
    }
    return key
}

func readFile(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("Couldn't read \(path).") }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "generate":
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation
    print("private=\((key.rawRepresentation + publicKey).base64EncodedString())")
    print("public=\(publicKey.base64EncodedString())")

case "public":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard arguments.count == 2 else { fail("usage: sign <file>") }
    let data = readFile(arguments[1])
    guard let signature = try? privateKey().signature(for: data) else { fail("Signing failed.") }
    print("signature=\(signature.base64EncodedString())")
    print("length=\(data.count)")

case "verify":
    guard arguments.count == 4 else { fail("usage: verify <file> <public-key> <signature>") }
    guard let keyBytes = Data(base64Encoded: arguments[2]), keyBytes.count == 32,
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
          let signature = Data(base64Encoded: arguments[3])
    else { fail("The public key or signature isn't valid base64 of the right size.") }
    if publicKey.isValidSignature(signature, for: readFile(arguments[1])) {
        print("valid")
    } else {
        fail("INVALID: the signature doesn't match this file and key.")
    }

default:
    fail("usage: ed25519.swift generate | public | sign <file> | verify <file> <public-key> <signature>")
}
