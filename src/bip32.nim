# Copyright (c) 2021 zenywallet

import bytes
import base58
import nimcrypto
import sequtils
import secp256k1
import utils
import address

const VersionMainnetPublic* = 0x0488B21E'u32
const VersionMainnetPrivate* = 0x0488ADE4'u32
const VersionTestnetPublic* = 0x043587CF'u32
const VersionTestnetPrivate* = 0x04358394'u32

type
  PrivateKey* = distinct seq[byte]
  PublicKey* = distinct seq[byte]
  PublicKeyObj* = distinct seq[byte]
  ChainCode* = distinct seq[byte]

  HDNode* = ref object
    depth*: uint8
    fingerprint*: uint32
    childNumber*: uint32
    chainCode*: ChainCode
    privateKey*: PrivateKey
    publicKey*: PublicKey

  EcError* = object of CatchableError
  HdError* = object of CatchableError


converter toBytes*(o: PrivateKey | PublicKey | PublicKeyObj | ChainCode): seq[byte] {.inline.} =
  cast[seq[byte]](o)
converter toPrivateKey*(s: seq[byte]): PrivateKey {.inline.} = PrivateKey(s)
converter toPublicKey*(s: seq[byte]): PublicKey {.inline.} = PublicKey(s)
converter toPublicKeyObj*(s: seq[byte]): PublicKeyObj {.inline.} = PublicKeyObj(s)
converter toChainCode*(s: seq[byte]): ChainCode {.inline.} = ChainCode(s)
converter toBytes*(o: secp256k1_pubkey): seq[byte] {.inline.} =
  (cast[array[64, byte]](o.data)).toSeq
converter toPublicKeyObj*(o: secp256k1_pubkey): PublicKeyObj {.inline.} =
  PublicKeyObj((cast[array[64, byte]](o.data)).toSeq)
converter toSecp256k1Pubkey*(o: PublicKeyObj): secp256k1_pubkey {.inline.} =
  cast[ptr secp256k1_pubkey](unsafeAddr (cast[ptr seq[byte]](unsafeAddr o))[0])[]

var secp256k1_ctx* {.threadvar.}: ptr secp256k1_context

proc init*() {.inline.} =
  secp256k1_ctx = secp256k1_context_create(SECP256K1_CONTEXT_VERIFY or SECP256K1_CONTEXT_SIGN)

proc free*() {.inline.} =
  secp256k1_context_destroy(secp256k1_ctx)

proc ctx*(): ptr secp256k1_context =
  if secp256k1_ctx.isNil:
    init()
  result = secp256k1_ctx

proc ecPubKeyCreate*(privateKey: PrivateKey): secp256k1_pubkey =
  if secp256k1_ec_pubkey_create(ctx(), addr result,
                                cast[ptr cuchar](addr cast[ptr seq[byte]](unsafeAddr privateKey)[0])) == 0:
    raise newException(EcError, "Impressive! verify privateKey failed")

proc ecPubKeySerializeCompressed*(pubkey: secp256k1_pubkey): seq[byte] =
  var publicKey = newSeq[byte](33)
  var outputlen = publicKey.len.csize_t
  if secp256k1_ec_pubkey_serialize(secp256k1_context_no_precomp, cast[ptr cuchar](addr publicKey[0]),
                                  addr outputlen, unsafeAddr pubkey, SECP256K1_EC_COMPRESSED) == 0:
    raise newException(EcError, "ecp256k1_ec_pubkey_serialize")
  result = publicKey

proc ecPubKeySerializeUncompressed*(pubkey: secp256k1_pubkey): seq[byte] =
  var publicKey = newSeq[byte](65)
  var outputlen = publicKey.len.csize_t
  if secp256k1_ec_pubkey_serialize(secp256k1_context_no_precomp, cast[ptr cuchar](addr publicKey[0]),
                                  addr outputlen, unsafeAddr pubkey, SECP256K1_EC_UNCOMPRESSED) == 0:
    raise newException(EcError, "ecp256k1_ec_pubkey_serialize")
  result = publicKey

proc pubUncompressed*(privateKey: PrivateKey): PublicKey =
  if privateKey.len != 32:
    raise newException(EcError, "pub privateKey len=" & $privateKey.len)
  var pubkey = ecPubKeyCreate(privateKey)
  result = ecPubKeySerializeUncompressed(pubkey)

proc pub*(privateKey: PrivateKey): PublicKey =
  if privateKey.len != 32:
    raise newException(EcError, "pub privateKey len=" & $privateKey.len)
  var pubkey = ecPubKeyCreate(privateKey)
  result = ecPubKeySerializeCompressed(pubkey)

proc pub*(publicKeyObj: PublicKeyObj): PublicKey =
  if publicKeyObj.len != 64:
    raise newException(EcError, "pub publicKeyObj len=" & $publicKeyObj.len)
  result = ecPubKeySerializeCompressed(publicKeyObj)

proc pubObj*(privateKey: PrivateKey): PublicKeyObj =
  if privateKey.len != 32:
    raise newException(EcError, "pubObj privateKey len=" & $privateKey.len)
  var pubkey = ecPubKeyCreate(privateKey)
  result = pubkey.toBytes

proc pubObj*(publicKey: PublicKey): PublicKeyObj =
  var pubkey: secp256k1_pubkey
  let srcPub = cast[ptr cuchar](unsafeAddr cast[ptr seq[byte]](unsafeAddr publicKey)[0])
  if secp256k1_ec_pubkey_parse(secp256k1_context_no_precomp, addr pubkey,
                              srcPub, publicKey.len.csize_t) == 0:
    raise newException(EcError, "secp256k1_ec_pubkey_parse")
  result = pubkey.toBytes

proc sign*(privateKey: PrivateKey, hash32: openArray[byte], grind: bool = true): seq[byte] =
  var sig: secp256k1_ecdsa_signature
  let priv = cast[ptr cuchar](unsafeAddr cast[ptr seq[byte]](unsafeAddr privateKey)[0])
  if secp256k1_ecdsa_sign(ctx(), addr sig, cast[ptr cuchar](unsafeAddr hash32[0]), priv,
                          secp256k1_nonce_function_rfc6979, nil) != 1:
    raise newException(EcError, "secp256k1_ecdsa_sign")
  if grind and not cast[array[64, byte]](sig)[31] < 0x80.byte:
    var ndata = newSeq[byte](32)
    var counter: uint32 = 1
    while true:
      copyMem(addr ndata[0], addr counter, sizeof(counter))
      if secp256k1_ecdsa_sign(ctx(), addr sig, cast[ptr cuchar](unsafeAddr hash32[0]), priv,
                              secp256k1_nonce_function_rfc6979, addr ndata[0]) != 1:
        raise newException(EcError, "secp256k1_ecdsa_sign")
      if cast[array[64, byte]](sig)[31] < 0x80.byte:
        break
      inc(counter)
  var der = newSeq[byte](75)
  var derLen = 75.csize_t
  if secp256k1_ecdsa_signature_serialize_der(ctx(), cast[ptr cuchar](addr der[0]), addr derLen, addr sig) != 1:
    raise newException(EcError, "secp256k1_ecdsa_signature_serialize_der")
  result = der[0..<derLen]

proc verify*(publicKeyObj: PublicKeyObj, hash: openArray[byte], der: openArray[byte]): bool =
  var sig: secp256k1_ecdsa_signature
  var derLen = der.len.csize_t
  if secp256k1_ecdsa_signature_parse_der(ctx(), addr sig, cast[ptr cuchar](unsafeAddr der[0]), derLen) != 1:
    return false
  secp256k1_ecdsa_signature_normalize(ctx(), addr sig, addr sig)
  let pubkey = cast[ptr secp256k1_pubkey](unsafeAddr cast[ptr seq[byte]](unsafeAddr publicKeyObj)[0])
  result = secp256k1_ecdsa_verify(ctx(), addr sig, cast[ptr cuchar](unsafeAddr hash[0]), pubkey) == 1

proc verify*(publicKey: PublicKey, hash: openArray[byte], der: openArray[byte]): bool {.inline.} =
  publicKey.pubObj.verify(hash, der)

proc master*(seed: seq[byte]): HDNode =
  var I = sha512.hmac("Bitcoin seed", seed).data
  var privateKey: PrivateKey = I[0..31].toBytes
  var chainCode: ChainCode = I[32..63].toBytes
  var node = new HDNode
  node.depth = 0
  node.fingerprint = 0
  node.childNumber = 0
  node.chainCode = chainCode
  node.privateKey = privateKey
  node.publicKey = pub(privateKey)
  result = node

proc addCheck*(data: seq[byte]): seq[byte] = concat(data, sha256d(data)[0..3])

proc check(data: seq[byte]): bool =
  var chk = data[^4..^1]
  if chk == sha256d(data[0..^5])[0..3]:
    return true
  return false

proc xprv*(node: HDNode): string =
  if node.privateKey.len != 32:
    raise newException(HdError, "xprv privateKey len=" & $node.privateKey.len)
  var d = (VersionMainnetPrivate, node.depth, node.fingerprint, node.childNumber,
          node.chainCode, 0x00'u8, node.privateKey).toBytesBE.addCheck
  base58.enc(d)

proc xpub*(node: HDNode): string =
  var d = (VersionMainnetPublic, node.depth, node.fingerprint, node.childNumber,
          node.chainCode, node.publicKey).toBytesBE.addCheck
  base58.enc(d)

proc node*(x: string): HDNode =
  var d = base58.dec(x)
  if not check(d):
    raise newException(HdError, "invalid serialization format")
  var node = new HDNode
  node.depth = d[4]
  node.fingerprint = d[5].toUint32BE
  node.childNumber = d[9].toUint32BE
  node.chainCode = d[13..44]
  var ver = d.toUint32BE
  if ver == VersionMainnetPublic:
    node.publicKey = d[45..77]
  elif ver == VersionMainnetPrivate:
    node.privateKey = d[46..77]
    node.publicKey = pub(node.privateKey)
  else:
    raise newException(HdError, "unknown version " & $ver.toBytesBE)
  result = node

proc tweakAdd*(privateKey: PrivateKey, tweak: seq[byte]): PrivateKey =
  if privateKey.len != 32 or tweak.len != 32:
    raise newException(EcError, "tweakAdd privateKey len=" & $privateKey.len & " tweak len=" & $tweak.len)
  var output: seq[byte] = privateKey
  if secp256k1_ec_privkey_tweak_add(ctx(), cast[ptr cuchar](addr output[0]),
                                    cast[ptr cuchar](unsafeAddr tweak[0])) == 0:
    raise newException(EcError, "secp256k1_ec_privkey_tweak_add")
  result = output

proc tweakAdd*(publicKeyObj: PublicKeyObj, tweak: seq[byte]): PublicKeyObj =
  if publicKeyObj.len != 64 or tweak.len != 32:
    raise newException(EcError, "tweakAdd publicKeyObj len=" & $publicKeyObj.len & " tweak len=" & $tweak.len)
  var output: seq[byte] = publicKeyObj
  if secp256k1_ec_pubkey_tweak_add(ctx(), cast[ptr secp256k1_pubkey](addr output[0]),
                                  cast[ptr cuchar](unsafeAddr tweak[0])) == 0:
    raise newException(EcError, "secp256k1_ec_pubkey_tweak_add")
  result = output

proc hardened*(node: HDNode, index: uint32): HDNode =
  if node.privateKey.len != 32:
    raise newException(HdError, "derive privateKey len=" & $node.privateKey.len)
  var childNumber = (0x80000000'u32 or index)
  var data = (0x00'u8, node.privateKey, childNumber).toBytesBE
  var I = sha512.hmac(node.chainCode.toBytes, data).data
  var privateKey: PrivateKey = I[0..31]
  var chainCode: ChainCode = I[32..63]
  var deriveNode = new HDNode
  deriveNode.depth = node.depth + 1
  deriveNode.fingerprint = ripemd160hash(node.publicKey).toBytes.toUint32BE
  deriveNode.childNumber = childNumber
  deriveNode.chainCode = chainCode
  deriveNode.privateKey = privateKey.tweakAdd(node.privateKey)
  deriveNode.publicKey = deriveNode.privateKey.pub
  result = deriveNode

proc derive*(node: HDNode, index: uint32): HDNode =
  var childNumber = index
  var data = (node.publicKey, childNumber).toBytesBE
  var I = sha512.hmac(node.chainCode.toBytes, data).data
  var privateKey: PrivateKey = I[0..31]
  var chainCode: ChainCode = I[32..63]
  var deriveNode = new HDNode
  deriveNode.depth = node.depth + 1
  deriveNode.fingerprint = ripemd160hash(node.publicKey).toBytes.toUint32BE
  deriveNode.childNumber = childNumber
  deriveNode.chainCode = chainCode
  if node.privateKey.len == 32:
    deriveNode.privateKey = privateKey.tweakAdd(node.privateKey)
    deriveNode.publicKey = deriveNode.privateKey.pub
  else:
    deriveNode.publicKey = node.publicKey.pubObj.tweakAdd(privateKey.toBytes).pub
  result = deriveNode

proc address*(node: HDNode, network: Network = defaultNetwork): string {.inline.} =
  node.publicKey.toAddress(network)

proc segwitAddress*(node: HDNode, network: Network = defaultNetwork): string {.inline.} =
  node.publicKey.toSegwitAddress(network)


when isMainModule:
  block test1:
    echo "--- Test vector 1"
    var seed = Hex("000102030405060708090a0b0c0d0e0f").toBytes
    echo "Seed: ", seed
    echo "Chain m"
    var m = bip32.master(seed)
    echo "ext pub: ", m.xpub()
    echo "ext prv: ", m.xprv()

    echo "Chain m/0'"
    var m_0h = m.hardened(0)
    echo "ext pub: ", m_0h.xpub()
    echo "ext prv: ", m_0h.xprv()

    echo "Chain m/0'/1"
    var m_0h_1 = m_0h.derive(1)
    echo "ext pub: ", m_0h_1.xpub()
    echo "ext prv: ", m_0h_1.xprv()

    echo "Chain m/0'/1/2'"
    var mm_0h_1_2h = m_0h_1.hardened(2)
    echo "ext pub: ", mm_0h_1_2h.xpub()
    echo "ext prv: ", mm_0h_1_2h.xprv()

    echo "Chain m/0'/1/2'/2"
    var mm_0h_1_2h_2 = mm_0h_1_2h.derive(2)
    echo "ext pub: ", mm_0h_1_2h_2.xpub()
    echo "ext prv: ", mm_0h_1_2h_2.xprv()

    echo "Chain m/0'/1/2'/2/1000000000"
    var mm_0h_1_2h_2_1000000000 = mm_0h_1_2h_2.derive(1000000000)
    echo "ext pub: ", mm_0h_1_2h_2_1000000000.xpub()
    echo "ext prv: ", mm_0h_1_2h_2_1000000000.xprv()

  block test2:
    echo "--- Test vector 2"
    var seed = Hex("fffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542").toBytes
    echo "Seed: ", seed
    echo "Chain m"
    var m = bip32.master(seed)
    echo "ext pub: ", m.xpub()
    echo "ext prv: ", m.xprv()

    echo "Chain m/0"
    var m_0 = m.derive(0)
    echo "ext pub: ", m_0.xpub()
    echo "ext prv: ", m_0.xprv()

    echo "Chain m/0/2147483647'"
    var m_0_2147483647h = m_0.hardened(2147483647)
    echo "ext pub: ", m_0_2147483647h.xpub()
    echo "ext prv: ", m_0_2147483647h.xprv()

    echo "Chain m/0/2147483647'/1"
    var m_0_2147483647h_1 = m_0_2147483647h.derive(1)
    echo "ext pub: ", m_0_2147483647h_1.xpub()
    echo "ext prv: ", m_0_2147483647h_1.xprv()

    echo "Chain m/0/2147483647'/1/2147483646'"
    var m_0_2147483647h_1_2147483646h = m_0_2147483647h_1.hardened(2147483646)
    echo "ext pub: ", m_0_2147483647h_1_2147483646h.xpub()
    echo "ext prv: ", m_0_2147483647h_1_2147483646h.xprv()

    echo "Chain m/0/2147483647'/1/2147483646'/2"
    var m_0_2147483647h_1_2147483646h_2 = m_0_2147483647h_1_2147483646h.derive(2)
    echo "ext pub: ", m_0_2147483647h_1_2147483646h_2.xpub()
    echo "ext prv: ", m_0_2147483647h_1_2147483646h_2.xprv()

  block test3:
    echo "--- Test vector 3"
    var seed = Hex("4b381541583be4423346c643850da4b320e46a87ae3d2a4e6da11eba819cd4acba45d239319ac14f863b8d5ab5a0d0c64d2e8a1e7d1457df2e5a3c51c73235be").toBytes
    echo "Seed: ", seed
    echo "Chain m"
    var m = bip32.master(seed)
    echo "ext pub: ", m.xpub()
    echo "ext prv: ", m.xprv()

    echo "Chain m/0'"
    var m_0h = m.hardened(0)
    echo "ext pub: ", m_0h.xpub()
    echo "ext prv: ", m_0h.xprv()
