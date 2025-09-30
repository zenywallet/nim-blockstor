# Copyright (c) 2021 zenywallet

import bytes
import base58
import sequtils
import eckey
import utils
import address

const VersionMainnetPublic* = 0x0488B21E'u32
const VersionMainnetPrivate* = 0x0488ADE4'u32
const VersionTestnetPublic* = 0x043587CF'u32
const VersionTestnetPrivate* = 0x04358394'u32

type
  ChainCode* = distinct seq[byte]

  HDNode* = ref object
    depth*: uint8
    fingerprint*: uint32
    childNumber*: uint32
    chainCode*: ChainCode
    privateKey*: PrivateKey
    publicKey*: PublicKey
    versionPub: uint32
    versionPrv: uint32

  HdError* = object of CatchableError


converter toBytes*(o: ChainCode): seq[byte] {.inline.} = cast[seq[byte]](o)
converter toChainCode*(s: seq[byte]): ChainCode {.inline.} = ChainCode(s)

proc master*(seed: seq[byte], versionPub: uint32, versionPrv: uint32): HDNode =
  var I = sha512Hmac("Bitcoin seed", seed)
  var privateKey: PrivateKey = I[0..31].toBytes
  var chainCode: ChainCode = I[32..63].toBytes
  var node = new HDNode
  node.depth = 0
  node.fingerprint = 0
  node.childNumber = 0
  node.chainCode = chainCode
  node.privateKey = privateKey
  node.publicKey = pub(privateKey)
  node.versionPub = versionPub
  node.versionPrv = versionPrv
  result = node

proc master*(seed: seq[byte], testnet: bool = false): HDNode =
  if testnet:
    result = master(seed, VersionTestnetPublic, VersionTestnetPrivate)
  else:
    result = master(seed, VersionMainnetPublic, VersionMainnetPrivate)

proc addCheck*(data: seq[byte]): seq[byte] = concat(data, sha256d(data)[0..3])

proc check(data: seq[byte]): bool =
  var chk = data[^4..^1]
  if chk == sha256d(data[0..^5])[0..3]:
    return true
  return false

proc xprv*(node: HDNode): string =
  if node.privateKey.len != 32:
    raise newException(HdError, "xprv privateKey len=" & $node.privateKey.len)
  var d = (node.versionPrv, node.depth, node.fingerprint, node.childNumber,
          node.chainCode, 0x00'u8, node.privateKey).toBytesBE.addCheck
  base58.enc(d)

proc xpub*(node: HDNode): string =
  var d = (node.versionPub, node.depth, node.fingerprint, node.childNumber,
          node.chainCode, node.publicKey).toBytesBE.addCheck
  base58.enc(d)

proc node*(x: string, testnet: bool = false): HDNode =
  var d = base58.dec(x)
  if not check(d):
    raise newException(HdError, "invalid serialization format")
  var node = new HDNode
  node.depth = d[4]
  node.fingerprint = d[5].toUint32BE
  node.childNumber = d[9].toUint32BE
  node.chainCode = d[13..44]
  var ver = d.toUint32BE
  if testnet:
    if ver == VersionTestnetPublic:
      node.publicKey = d[45..77]
      node.versionPub = VersionTestnetPublic
    elif ver == VersionTestnetPrivate:
      node.privateKey = d[46..77]
      node.publicKey = pub(node.privateKey)
      node.versionPub = VersionTestnetPublic
      node.versionPrv = VersionTestnetPrivate
    else:
      raise newException(HdError, "unknown version " & $ver.toBytesBE)
  else:
    if ver == VersionMainnetPublic:
      node.publicKey = d[45..77]
      node.versionPub = VersionMainnetPublic
    elif ver == VersionMainnetPrivate:
      node.privateKey = d[46..77]
      node.publicKey = pub(node.privateKey)
      node.versionPub = VersionMainnetPublic
      node.versionPrv = VersionMainnetPrivate
    else:
      raise newException(HdError, "unknown version " & $ver.toBytesBE)
  result = node

proc hardened*(node: HDNode, index: uint32): HDNode =
  if node.privateKey.len != 32:
    raise newException(HdError, "derive privateKey len=" & $node.privateKey.len)
  var childNumber = (0x80000000'u32 or index)
  var data = (0x00'u8, node.privateKey, childNumber).toBytesBE
  var I = sha512Hmac(node.chainCode.toBytes, data)
  var privateKey: PrivateKey = I[0..31]
  var chainCode: ChainCode = I[32..63]
  var deriveNode = new HDNode
  deriveNode.depth = node.depth + 1
  deriveNode.fingerprint = ripemd160hash(node.publicKey).toBytes.toUint32BE
  deriveNode.childNumber = childNumber
  deriveNode.chainCode = chainCode
  deriveNode.privateKey = privateKey.tweakAdd(node.privateKey)
  deriveNode.publicKey = deriveNode.privateKey.pub
  deriveNode.versionPub = node.versionPub
  deriveNode.versionPrv = node.versionPrv
  result = deriveNode

proc derive*(node: HDNode, index: uint32): HDNode =
  var childNumber = index
  var data = (node.publicKey, childNumber).toBytesBE
  var I = sha512Hmac(node.chainCode.toBytes, data)
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
  deriveNode.versionPub = node.versionPub
  deriveNode.versionPrv = node.versionPrv
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
