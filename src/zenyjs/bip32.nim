# Copyright (c) 2021 zenywallet

when defined(js):
  import jsffi
  import jslib

  type
    HDNode* = object
      handle*: JsObject

  var Bip32Mod = JsObject{}
  var Module: JsObject

  proc init*(module: JsObject) =
    Module = module
    Bip32Mod.free = Module.cwrap("bip32_free", jsNull, [NumVar])
    Bip32Mod.duplicate = Module.cwrap("bip32_duplicate", NumVar, [NumVar])
    Bip32Mod.master = Module.cwrap("bip32_master", NumVar, [NumVar, NumVar, NumVar])
    Bip32Mod.xprv = Module.cwrap("bip32_xprv", NumVar, [NumVar])
    Bip32Mod.xpub = Module.cwrap("bip32_xpub", NumVar, [NumVar])
    Bip32Mod.node = Module.cwrap("bip32_node", NumVar, [NumVar, NumVar])
    Bip32Mod.hardened = Module.cwrap("bip32_hardened", NumVar, [NumVar, NumVar])
    Bip32Mod.derive = Module.cwrap("bip32_derive", NumVar, [NumVar, NumVar])
    Bip32Mod.address = Module.cwrap("bip32_address", NumVar, [NumVar, NumVar])
    Bip32Mod.segwitAddress = Module.cwrap("bip32_segwitAddress", NumVar, [NumVar, NumVar])
    Bip32Mod.xprvEx = Module.cwrap("bip32_xprv_ex", NumVar, [NumVar, NumVar])
    Bip32Mod.xpubEx = Module.cwrap("bip32_xpub_ex", NumVar, [NumVar, NumVar])
    Bip32Mod.addressEx = Module.cwrap("bip32_address_ex", NumVar, [NumVar, NumVar, NumVar])
    Bip32Mod.segwitAddressEx = Module.cwrap("bip32_segwitAddress_ex", NumVar, [NumVar, NumVar, NumVar])

  proc duplicate(handle: JsObject): JsObject =
    result = Bip32Mod.duplicate(handle)
    return result

  proc `=destroy`*(node: var HDNode) =
    if not node.handle.isNil:
      Bip32Mod.free(node.handle)
      node.handle = jsNull

  proc `=copy`*(a: var HDNode; b: HDNode) =
    `=destroy`(a)
    if not b.handle.isNil:
      a.handle = b.handle.duplicate()

  proc `=sink`*(a: var HDNode; b: HDNode) =
    `=destroy`(a)
    if not b.handle.isNil:
      a.handle = b.handle

  proc master*(seed: Uint8Array, testnet: bool = false): HDNode =
    var pdata = Module.malloc(seed.length.to(int))
    Module.HEAPU8.set(seed, pdata)
    result.handle = Bip32Mod.master(pdata, seed.length.to(int), false)
    Module.free(pdata)
    return result

  proc xprv*(node: HDNode): cstring =
    var p = Bip32Mod.xprv(node.handle)
    var a = newUint8Array(Module.HEAPU8.buffer, p.to(int), 256)
    var s = a.slice(0, a.indexOf(0)).uint8ArrayToStr()
    return s

  proc xpub*(node: HDNode): cstring =
    var p = Bip32Mod.xpub(node.handle)
    var a = newUint8Array(Module.HEAPU8.buffer, p.to(int), 256)
    var s = a.slice(0, a.indexOf(0)).uint8ArrayToStr()
    return s

  proc xprvEx*(node: HDNode): cstring =
    var p = Module.malloc(4)
    var size = Bip32Mod.xprvEx(node.handle, p)
    var outBuf = newUint32Array(Module.HEAPU32.buffer, p.to(int), 1)[0]
    var a = newUint8Array(Module.HEAPU8.buffer, outBuf.to(int), size.to(int)).slice()
    var s = a.uint8ArrayToStr()
    return s

  proc xpubEx*(node: HDNode): cstring =
    var p = Module.malloc(4)
    var size = Bip32Mod.xpubEx(node.handle, p)
    var outBuf = newUint32Array(Module.HEAPU32.buffer, p.to(int), 1)[0]
    var a = newUint8Array(Module.HEAPU8.buffer, outBuf.to(int), size.to(int)).slice()
    var s = a.uint8ArrayToStr()
    return s

  proc node*(x: cstring, testnet: bool = false): HDNode =
    var a = strToUint8Array(x)
    var size = a.length.to(cint)
    var p = Module.malloc(size)
    Module.HEAPU8.set(a, p)
    result.handle = Bip32Mod.node(p, testnet)

  proc hardened*(node: HDNode, index: int): HDNode =
    result.handle = Bip32Mod.hardened(node.handle, index)

  proc derive*(node: HDNode, index: int): HDNode =
    result.handle = Bip32Mod.derive(node.handle, index)

  proc address*(node: HDNode, networkId: int = 0): cstring =
    var p = Bip32Mod.address(node.handle, networkId)
    var a = newUint8Array(Module.HEAPU8.buffer, p.to(int), 256)
    var s = a.slice(0, a.indexOf(0)).uint8ArrayToStr()
    return s

  proc segwitAddress*(node: HDNode, networkId: int = 0): cstring =
    var p = Bip32Mod.segwitAddress(node.handle, networkId)
    var a = newUint8Array(Module.HEAPU8.buffer, p.to(int), 256)
    var s = a.slice(0, a.indexOf(0)).uint8ArrayToStr()
    return s

  proc addressEx*(node: HDNode, networkId: int = 0): cstring =
    var p = Module.malloc(4)
    var size = Bip32Mod.addressEx(node.handle, networkId, p)
    var outBuf = newUint32Array(Module.HEAPU32.buffer, p.to(int), 1)[0]
    var a = newUint8Array(Module.HEAPU8.buffer, outBuf.to(int), size.to(int)).slice()
    var s = a.uint8ArrayToStr()
    return s

  proc segwitAddressEx*(node: HDNode, networkId: int = 0): cstring =
    var p = Module.malloc(4)
    var size = Bip32Mod.segwitAddressEx(node.handle, networkId, p)
    var outBuf = newUint32Array(Module.HEAPU32.buffer, p.to(int), 1)[0]
    var a = newUint8Array(Module.HEAPU8.buffer, outBuf.to(int), size.to(int)).slice()
    var s = a.uint8ArrayToStr()
    return s

else:
  when defined(emscripten):
    const EXPORTED_FUNCTIONS* = ["_bip32_free", "_bip32_master", "_bip32_xprv", "_bip32_xpub", "_bip32_node",
                                "_bip32_hardened", "_bip32_derive", "_bip32_address", "_bip32_segwitAddress",
                                "_bip32_duplicate", "_bip32_xprv_ex", "_bip32_xpub_ex",
                                "_bip32_address_ex", "_bip32_segwitAddress_ex"]

  import bytes
  import base58
  import nimcrypto
  import sequtils
  import eckey
  import utils
  import address
  import arraylib

  const VersionMainnetPublic* = 0x0488B21E'u32
  const VersionMainnetPrivate* = 0x0488ADE4'u32
  const VersionTestnetPublic* = 0x043587CF'u32
  const VersionTestnetPrivate* = 0x04358394'u32

  type
    ChainCode* = distinct Array[byte]

    HDNodeObj = object
      depth*: uint8
      fingerprint*: uint32
      childNumber*: uint32
      chainCode*: ChainCode
      privateKey*: PrivateKey
      publicKey*: PublicKey
      versionPub: uint32
      versionPrv: uint32
      xprv: cstring
      xpub: cstring
      address: cstring
      segwitAddress: cstring

    HDNode* = ptr HDNodeObj

    HdError* = object of CatchableError

  converter toBytes*(o: ChainCode): Array[byte] = cast[Array[byte]](o)
  converter toChainCode*(s: Array[byte]): ChainCode {.inline.} = ChainCode(s)

  proc free*(node: HDNode) {.exportc: "bip32_$1".} =
    if not node.segwitAddress.isNil:
      node.segwitAddress.deallocShared()
    if not node.address.isNil:
      node.address.deallocShared()
    if not node.xpub.isNil:
      node.xpub.deallocShared()
    if not node.xprv.isNil:
      node.xprv.deallocShared()
    `=destroy`(node.publicKey)
    `=destroy`(node.privateKey)
    `=destroy`(node.chainCode)
    node.deallocShared()

  proc duplicate*(node: HDNode): HDNode {.exportc: "bip32_$1".} =
    result = cast[HDNode](allocShared0(sizeof(HDNodeObj)))
    result.depth = node.depth
    result.fingerprint = node.fingerprint
    result.childNumber = node.childNumber
    result.chainCode = node.chainCode
    result.privateKey = node.privateKey
    result.publicKey = node.publicKey
    result.versionPub = node.versionPub
    result.versionPrv = node.versionPrv

  proc master*(seed: Array[byte], versionPub: uint32, versionPrv: uint32): HDNode =
    result = cast[HDNode](allocShared0(sizeof(HDNodeObj)))
    var I = sha512.hmac("Bitcoin seed", seed.toSeq).data
    result.depth = 0
    result.fingerprint = 0
    result.childNumber = 0
    result.chainCode = I[32..63].toBytes
    result.privateKey = I[0..31].toBytes
    result.publicKey = result.privateKey.toBytes.PrivateKey.pub.toBytes
    result.versionPub = versionPub
    result.versionPrv = versionPrv

  proc master*(seed: Array[byte], testnet: bool = false): HDNode =
    if testnet:
      result = master(seed, VersionTestnetPublic, VersionTestnetPrivate)
    else:
      result = master(seed, VersionMainnetPublic, VersionMainnetPrivate)

  proc master*(seedBuf: ptr UncheckedArray[byte], seedSize: int, testnet: bool = false): HDNode {.exportc: "bip32_$1".} =
    var seed = seedBuf.toBytes(seedSize)
    result = master(seed, testnet)

  proc addCheck*(data: Array[byte]): Array[byte] = concat(data.toSeq, sha256d(data)[0..3]).toBytes

  proc check(data: Array[byte]): bool =
    var chk = data[^4..^1]
    if chk == sha256d(data[0..^5])[0..3].toArray:
      return true
    return false

  proc set(p: var cstring, s: string): cstring {.discardable.} =
    if not p.isNil:
      p.deallocShared()
    var len = s.len
    p = cast[cstring](allocShared0(len + 1))
    copyMem(p, unsafeAddr s[0], len)
    result = p

  proc xprv*(node: HDNode): cstring {.exportc: "bip32_$1".} =
    if node.privateKey.len != 32:
      raise newException(HdError, "xprv privateKey len=" & $node.privateKey.len)
    var d = (node.versionPrv, node.depth, node.fingerprint, node.childNumber,
            node.chainCode, 0x00'u8, node.privateKey.toBytes).toBytesBE.addCheck
    var s = base58.enc(d)
    node.xprv.set(s)

  proc xpub*(node: HDNode): cstring {.exportc: "bip32_$1".} =
    var d = (node.versionPub, node.depth, node.fingerprint, node.childNumber,
            node.chainCode, node.publicKey).toBytesBE.addCheck
    var s = base58.enc(d)
    node.xpub.set(s)

  proc xprv*(node: HDNode, xprv: ptr cstring): cint {.exportc: "bip32_$1_ex".} =
    if node.privateKey.len != 32:
      raise newException(HdError, "xprv privateKey len=" & $node.privateKey.len)
    var d = (node.versionPrv, node.depth, node.fingerprint, node.childNumber,
            node.chainCode, 0x00'u8, node.privateKey.toBytes).toBytesBE.addCheck
    var s = base58.enc(d)
    node.xprv.set(s)
    xprv[] = node.xprv
    result = s.len.cint

  proc xpub*(node: HDNode, xpub: ptr cstring): cint {.exportc: "bip32_$1_ex".} =
    var d = (node.versionPub, node.depth, node.fingerprint, node.childNumber,
            node.chainCode, node.publicKey).toBytesBE.addCheck
    var s = base58.enc(d)
    node.xpub.set(s)
    xpub[] = node.xpub
    result = s.len.cint

  proc node*(x: cstring, testnet: bool = false): HDNode {.exportc: "bip32_$1".} =
    var d = base58.dec(toString(cast[ptr UncheckedArray[byte]](x), x.len))
    if not check(d):
      raise newException(HdError, "invalid serialization format")
    var node = cast[HDNode](allocShared0(sizeof(HDNodeObj)))
    node.depth = d[4]
    node.fingerprint = d[5].toUint32BE
    node.childNumber = d[9].toUint32BE
    node.chainCode = d[13..44].toBytes
    var ver = d.toUint32BE
    if testnet:
      if ver == VersionTestnetPublic:
        node.publicKey = d[45..77].toBytes
        node.versionPub = VersionTestnetPublic
      elif ver == VersionTestnetPrivate:
        node.privateKey = d[46..77].toBytes
        node.publicKey = node.privateKey.toBytes.PrivateKey.pub.toBytes
        node.versionPub = VersionTestnetPublic
        node.versionPrv = VersionTestnetPrivate
      else:
        raise newException(HdError, "unknown version " & $ver.toBytesBE)
    else:
      if ver == VersionMainnetPublic:
        node.publicKey = d[45..77].toBytes
        node.versionPub = VersionMainnetPublic
      elif ver == VersionMainnetPrivate:
        node.privateKey = d[46..77].toBytes
        node.publicKey = node.privateKey.toBytes.PrivateKey.pub.toBytes
        node.versionPub = VersionMainnetPublic
        node.versionPrv = VersionMainnetPrivate
      else:
        raise newException(HdError, "unknown version " & $ver.toBytesBE)
    result = node

  proc hardened*(node: HDNode, index: uint32): HDNode {.exportc: "bip32_$1".} =
    if node.privateKey.len != 32:
      raise newException(HdError, "derive privateKey len=" & $node.privateKey.len)
    var childNumber = (0x80000000'u32 or index)
    var data = (0x00'u8, node.privateKey, childNumber).toBytesBE
    var I = sha512.hmac(node.chainCode.toBytes.toSeq, data.toSeq).data.toBytes
    var privateKey: PrivateKey = I[0..31]
    var chainCode: ChainCode = I[32..63]
    var deriveNode = cast[HDNode](allocShared0(sizeof(HDNodeObj)))
    deriveNode.depth = node.depth + 1
    deriveNode.fingerprint = ripemd160hash(node.publicKey.toBytes.PublicKey).toBytes.toUint32BE
    deriveNode.childNumber = childNumber
    deriveNode.chainCode = chainCode.toBytes
    deriveNode.privateKey = privateKey.tweakAdd(node.privateKey.toBytes.PrivateKey).toBytes
    deriveNode.publicKey = deriveNode.privateKey.toBytes.PrivateKey.pub.toBytes
    deriveNode.versionPub = node.versionPub
    deriveNode.versionPrv = node.versionPrv
    result = deriveNode

  proc derive*(node: HDNode, index: uint32): HDNode {.exportc: "bip32_$1".} =
    var childNumber = index
    var data = (node.publicKey, childNumber).toBytesBE
    var I = sha512.hmac(node.chainCode.toBytes.toSeq, data.toSeq).data.toBytes
    var privateKey: PrivateKey = I[0..31]
    var chainCode: ChainCode = I[32..63]
    var deriveNode = cast[HDNode](allocShared0(sizeof(HDNodeObj)))
    deriveNode.depth = node.depth + 1
    deriveNode.fingerprint = ripemd160hash(node.publicKey.toBytes.PublicKey).toBytes.toUint32BE
    deriveNode.childNumber = childNumber
    deriveNode.chainCode = chainCode.toBytes
    if node.privateKey.len == 32:
      deriveNode.privateKey = privateKey.tweakAdd(node.privateKey.toBytes.PrivateKey).toBytes
      deriveNode.publicKey = deriveNode.privateKey.toBytes.PrivateKey.pub.toBytes
    else:
      deriveNode.publicKey = node.publicKey.toBytes.PublicKey.pubObj.tweakAdd(privateKey.toBytes.PrivateKey).pub.toBytes
    deriveNode.versionPub = node.versionPub
    deriveNode.versionPrv = node.versionPrv
    result = deriveNode

  proc address*(node: HDNode, networkId: NetworkId): cstring {.exportc: "bip32_$1".} =
    var network = getNetwork(networkId)
    var s = node.publicKey.toBytes.PublicKey.toAddress(network)
    node.address.set(s)

  proc segwitAddress*(node: HDNode, networkId: NetworkId): cstring {.exportc: "bip32_$1".} =
    var network = getNetwork(networkId)
    var s = node.publicKey.toBytes.PublicKey.toSegwitAddress(network)
    node.segwitAddress.set(s)

  proc address*(node: HDNode, networkId: NetworkId, outAddress: ptr cstring): cint {.exportc: "bip32_$1_ex".} =
    var network = getNetwork(networkId)
    var s = node.publicKey.toBytes.PublicKey.toAddress(network)
    node.address.set(s)
    outAddress[] = node.address
    result = s.len.cint

  proc segwitAddress*(node: HDNode, networkId: NetworkId, outAddress: ptr cstring): cint {.exportc: "bip32_$1_ex".} =
    var network = getNetwork(networkId)
    var s = node.publicKey.toBytes.PublicKey.toSegwitAddress(network)
    node.segwitAddress.set(s)
    outAddress[] = node.segwitAddress
    result = s.len.cint
