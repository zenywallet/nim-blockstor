# Copyright (c) 2020 zenywallet

type
  Network* = object
    pubKeyPrefix*: uint8
    scriptPrefix*: uint8
    wif*: uint8
    bech32*: string
    bech32Extra*: seq[string]
    testnet*: bool

  AddressType* {.pure.} = enum
    Unknown
    P2PKH
    P2SH
    P2SH_P2WPKH
    P2WPKH

import os, macros
macro includeConfig: untyped =
  const configFile = currentSourcePath().parentDir() / ".." / "config.nim"
  var existTest = staticExec("test -f \"" & configFile & "\" && echo \"find\"")
  if existTest.len > 0:
    nnkStmtList.newTree(
      nnkIncludeStmt.newTree(
        newIdentNode("../config")
      )
    )
  else:
    nnkStmtList.newTree(
      nnkIncludeStmt.newTree(
        newIdentNode("../config_default")
      )
    )
includeConfig()

when defined(js):
  import jsffi
  import jslib

  var AddressMod = JsObject{}
  var Module: JsObject

  proc init*(module: JsObject) =
    Module = module
    AddressMod.checkAddress = Module.cwrap("address_checkAddress", NumVar, [NumVar])

  template withStack*(body: untyped) =
    block stackBlock:
      var stack = Module.stackSave()
      defer:
        Module.stackRestore(stack)
      body

  proc checkAddress*(networkId: int, address: cstring): bool =
    withStack:
      var addressUint8Array = strToUint8Array(address)
      var p = Module.stackAlloc(addressUint8Array.length.to(int) + 1)
      Module.HEAPU8.set(addressUint8Array, p)
      Module.HEAPU8[p.to(int) + addressUint8Array.length.to(int)] = 0
      result = AddressMod.checkAddress(networkId, p).to(bool)

else:
  when defined(emscripten):
    const EXPORTED_FUNCTIONS* = ["_address_checkAddress"]

  import strutils, nimcrypto
  import script
  import ../segwit
  import ../opcodes
  import bytes
  import utils
  import base58
  import arraylib

  template getNetwork*(networkId: NetworkId): Network = Networks[networkId.int]

  proc ripemd160hash*(pub: Array[byte]): Hash160 =
    Hash160(ripemd160.digest(sha256s(pub)).data.toArray)

  proc checkSum(hash160Prefix: Array[byte]): Array[byte] =
    let hashd = sha256d(hash160Prefix)
    result = hashd[0..3].toArray

  proc check(prefix: uint8, hash160: Hash160): Array[byte] =
    let hash160Prefix = (prefix, hash160).toBytes
    let hashd = sha256d(hash160Prefix)
    result = concat(hash160Prefix, hashd[0..3].toArray)

  proc p2pkh_address*(network: NetWork | NetworkId, hash160: Hash160): string =
    when network is NetworkId:
      let network = network.getNetwork
    let binaddr = check(network.pubkeyPrefix, hash160)
    result = base58.enc(binaddr)

  proc p2sh_address*(network: NetWork | NetworkId, hash160: Hash160): string =
    when network is NetworkId:
      let network = network.getNetwork
    let binaddr = check(network.scriptPrefix, hash160)
    result = base58.enc(binaddr)

  proc p2sh_p2wpkh_address*(network: NetWork | NetworkId, hash160: Hash160): string =
    when network is NetworkId:
      let network = network.getNetwork
    let script = (OP_0, PushData(hash160)).toBytes
    let binaddr = check(network.scriptPrefix, ripemd160hash(script))
    result = base58.enc(binaddr)

  proc p2wpkh_address*(network: NetWork | NetworkId, hash160: Hash160): string =
    when network is NetworkId:
      let network = network.getNetwork
    var data = hash160.toBytes
    var output = newString(128)
    let ret = segwit_addr_encode(output.cstring, network.bech32.cstring, 0.cint, unsafeAddr data[0], data.len.csize_t)
    if ret == 1:
      var pos = 0
      for i, c in output:
        if not c.isAlphaNumeric():
          break
        pos = i
      result = output[0..pos]

  proc getAddress*(network: NetWork | NetworkId, pub: Array[byte]): string {.inline.} =
    network.p2pkh_address(ripemd160hash(pub))

  proc getSegwitAddress*(network: NetWork | NetworkId, pub: Array[byte]): string {.inline.} =
    network.p2wpkh_address(ripemd160hash(pub))

  proc getAddress*(network: NetWork | NetworkId, hash160: Hash160, addressType: AddressType): string =
    case addressType
    of P2PKH:
      result = network.p2pkh_address(hash160)
    of P2SH:
      result = network.p2sh_address(hash160)
    of P2SH_P2WPKH:
      result = network.p2sh_p2wpkh_address(hash160)
    of P2WPKH:
      result = network.p2wpkh_address(hash160)
    else:
      result = ""

  var defaultNetworkId* {.threadvar.}: NetworkId

  proc setDefaultNetworkId*(networkId: NetworkId) {.inline.} =
    defaultNetworkId = networkId

  template toAddress*(pub: Array[byte], networkId: NetworkId = defaultNetworkId): string = getAddress(networkId, pub)
  template toAddress*(pub: Array[byte], network: Network): string = getAddress(network, pub)

  template toSegwitAddress*(pub: Array[byte], networkId: NetworkId = defaultNetworkId): string = getSegwitAddress(networkId, pub)
  template toSegwitAddress*(pub: Array[byte], network: Network): string = getSegwitAddress(network, pub)

  proc getAddressHash160*(script: Script | Chunks): tuple[hash160: Hash160, addressType: AddressType] =
    when script is Script:
      var chunks = script.getScriptChunks
    else:
      var chunks = script
    if chunks.len == 5:
      if chunks[0].type == ChunkType.Code and chunks[0].op == Opcode.OP_DUP and
        chunks[1].type == ChunkType.Code and chunks[1].op == Opcode.OP_HASH160 and
        chunks[2].type == ChunkType.Data and chunks[2].data.len == 20 and
        chunks[3].type == ChunkType.Code and chunks[3].op == Opcode.OP_EQUALVERIFY and
        chunks[4].type == ChunkType.Code and chunks[4].op == Opcode.OP_CHECKSIG:

        return (Hash160(chunks[2].data), AddressType.P2PKH)

    elif chunks.len == 3:
      if chunks[0].type == ChunkType.Code and chunks[0].op == Opcode.OP_HASH160 and
        chunks[1].type == ChunkType.Data and chunks[1].data.len == 20 and
        chunks[2].type == ChunkType.Code and chunks[2].op == Opcode.OP_EQUAL:

        return (Hash160(chunks[1].data), AddressType.P2SH)

    elif chunks.len == 2:
      if chunks[0].type == ChunkType.Data and chunks[0].data.len == 33 and
        chunks[1].type == ChunkType.Code and chunks[1].op == Opcode.OP_CHECKSIG:

        return (ripemd160hash(chunks[0].data), AddressType.P2PKH)

      elif chunks[0].type == ChunkType.Code and chunks[0].op == Opcode.OP_0 and
        chunks[1].type == ChunkType.Data:

        if chunks[1].data.len == 20:
          return (Hash160(chunks[1].data), AddressType.P2WPKH)

        elif chunks[1].data.len == 32:
          return (ripemd160hash(chunks[1].data), AddressType.P2WPKH)

  proc getAddress*(network: NetWork | NetworkId, script: Script | Chunks): string =
    var addrHash = getAddressHash160(script)
    case addrHash.addressType
    of AddressType.P2PKH: network.p2pkh_address(addrHash.hash160)
    of AddressType.P2SH: network.p2sh_address(addrHash.hash160)
    of AddressType.P2WPKH: network.p2wpkh_address(addrHash.hash160)
    of AddressType.P2SH_P2WPKH: network.p2sh_p2wpkh_address(addrHash.hash160)
    of AddressType.Unknown: ""

  proc getAddresses*(network: NetWork | NetworkId, script: Script | Chunks): seq[string] =
    var a = network.getAddress(script)
    if a.len > 0:
      result.add(a)
      return

    # not yet implemented, only for debugging purposes
    when script is Script:
      var chunks = script.getScriptChunks
    else:
      var chunks = script
    for chunk in chunks:
      if chunk.type == ChunkType.Data:
        if chunk.data.len == 33:
          result.add(network.p2pkh_address(ripemd160hash(chunk.data)))
        elif chunk.data.len == 20:
          result.add(network.p2pkh_address(Hash160(chunk.data)))

  proc checkAddress*(address: string): bool =
    result = false
    var binaddr = base58.dec(address)
    if binaddr.len == 25: # prefix(1), hash160(20), checksum(4)
      let ck = binaddr[^4..^1]
      let test_ck = checkSum(binaddr[0..^5])
      if ck == test_ck:
        result = true

  proc getHash160*(address: string): Hash160 =
    var binaddr = base58.dec(address)
    if binaddr.len == 25: # prefix(1), hash160(20), checksum(4)
      result = Hash160(binaddr[1..^5])

  proc p2wpkh_hash160(address: string, bech32Prefix: string): Hash160 =
    var version: cint = 0
    var programm = newArray[byte](40)
    var programmlen: csize_t = 0
    if segwit_addr_decode(addr version, addr programm[0], addr programmlen, bech32Prefix, address) == 1:
      if programmlen == 20:
        result = Hash160(programm[0..<20])

  proc getHash160*(network: NetWork | NetworkId, address: string): Hash160 =
    when network is NetworkId:
      let network = network.getNetwork
    if address.startsWith(network.bech32):
      return p2wpkh_hash160(address, network.bech32)
    elif network.bech32Extra.len > 0:
      for bech32 in network.bech32Extra:
        if address.startsWith(bech32):
          return p2wpkh_hash160(address, bech32)
    return getHash160(address)

  proc p2pkh_script*(address: string): Array[byte] =
    var binaddr = base58.dec(address)
    if binaddr.len == 25: # prefix(1), hash160(20), checksum(4)
      result = (OP_DUP, OP_HASH160, ChunkData(binaddr[1..^5]), OP_EQUALVERIFY, OP_CHECKSIG).toBytes

  proc p2sh_script*(address: string): Array[byte] =
    var binaddr = base58.dec(address)
    if binaddr.len == 25: # prefix(1), hash160(20), checksum(4)
      result = (OP_HASH160, ChunkData(binaddr[1..^5]), OP_EQUAL).toBytes

  proc p2wpkh_script*(address: string, bech32Prefix: string): Array[byte] =
    var version: cint = 0
    var programm = newArray[byte](40)
    var programmlen: csize_t = 0
    if segwit_addr_decode(addr version, addr programm[0], addr programmlen, bech32Prefix, address) == 1:
      if programmlen == 20:
        result = (OP_0, ChunkData(programm[0..<20])).toBytes

  proc getScript*(network: NetWork | NetworkId, address: string): Array[byte] =
    when network is NetworkId:
      let network = network.getNetwork
    var binaddr = base58.dec(address)
    if binaddr.len == 25:
      if binaddr[0] == network.pubKeyPrefix:
        result = (OP_DUP, OP_HASH160, ChunkData(binaddr[1..^5]), OP_EQUALVERIFY, OP_CHECKSIG).toBytes
      elif binaddr[0] == network.scriptPrefix:
        result = (OP_HASH160, ChunkData(binaddr[1..^5]), OP_EQUAL).toBytes
    elif address.startsWith(network.bech32):
      result = p2wpkh_script(address, network.bech32)
    else:
      for bech32 in network.bech32Extra:
        if address.startsWith(bech32):
          result = p2wpkh_script(address, bech32)

  proc getHash160AddressType*(network: NetWork | NetworkId, address: string): tuple[hash160: Hash160, addressType: AddressType] =
    when network is NetworkId:
      let network = network.getNetwork
    var binaddr = base58.dec(address)
    if binaddr.len == 25:
      if binaddr[0] == network.pubKeyPrefix:
        result = (binaddr[1..^5].Hash160, AddressType.P2PKH)
      elif binaddr[0] == network.scriptPrefix:
        result = (binaddr[1..^5].Hash160, AddressType.P2SH)
    elif address.startsWith(network.bech32):
      let s = p2wpkh_script(address, network.bech32)
      result = (s[2..^1].Hash160, AddressType.P2WPKH)
    else:
      for bech32 in network.bech32Extra:
        if address.startsWith(bech32):
          let s = p2wpkh_script(address, network.bech32)
          result = (s[2..^1].Hash160, AddressType.P2WPKH)
          break

  proc checkAddress*(networkId: NetworkId, address: string): bool =
    let network = networkId.getNetwork
    var binaddr = base58.dec(address)
    if binaddr.len == 25:
      if binaddr[0] == network.pubKeyPrefix:
        result = true
      elif binaddr[0] == network.scriptPrefix:
        result = true
    elif address.startsWith(network.bech32):
      let s = p2wpkh_script(address, network.bech32)
      if s.len > 0:
        result = true
    else:
      for bech32 in network.bech32Extra:
        if address.startsWith(bech32):
          let s = p2wpkh_script(address, network.bech32)
          if s.len > 0:
            result = true
            break

  proc checkAddress*(networkId: NetworkId, address: cstring): bool {.exportc: "address_$1".} =
    checkAddress(networkId, $address)


  when isMainModule:
    var bitzeny_test = NetworkId.BitZeny_testnet
    var hash160_p2pkh = bitzeny_test.getHash160("mnfJyrnDZSDnaNUkognbRsbQNUanoNHArK")
    assert bitzeny_test.p2pkh_address(hash160_p2pkh) == "mnfJyrnDZSDnaNUkognbRsbQNUanoNHArK"
    assert bitzeny_test.p2sh_address(hash160_p2pkh) == "2MzPag67humcG6DL7tM6geXjGsMUyCcAU7B"
    assert bitzeny_test.p2sh_p2wpkh_address(hash160_p2pkh) == "2NCGV4pFRiFc5449Psz2jeES3K3qCM6x1uk"
    assert bitzeny_test.p2wpkh_address(hash160_p2pkh) == "tz1qfewhn63wyzfjca43vcc0zpwfq89wu6z6yavtql"

    var hash160_p2sh = bitzeny_test.getHash160("2MzPag67humcG6DL7tM6geXjGsMUyCcAU7B")
    assert bitzeny_test.p2pkh_address(hash160_p2sh) == "mnfJyrnDZSDnaNUkognbRsbQNUanoNHArK"
    assert bitzeny_test.p2sh_address(hash160_p2sh) == "2MzPag67humcG6DL7tM6geXjGsMUyCcAU7B"
    assert bitzeny_test.p2sh_p2wpkh_address(hash160_p2sh) == "2NCGV4pFRiFc5449Psz2jeES3K3qCM6x1uk"
    assert bitzeny_test.p2wpkh_address(hash160_p2sh) == "tz1qfewhn63wyzfjca43vcc0zpwfq89wu6z6yavtql"

    var hash160_p2wpkh = bitzeny_test.getHash160("tz1qfewhn63wyzfjca43vcc0zpwfq89wu6z6yavtql")
    assert bitzeny_test.p2pkh_address(hash160_p2wpkh) == "mnfJyrnDZSDnaNUkognbRsbQNUanoNHArK"
    assert bitzeny_test.p2sh_address(hash160_p2wpkh) == "2MzPag67humcG6DL7tM6geXjGsMUyCcAU7B"
    assert bitzeny_test.p2sh_p2wpkh_address(hash160_p2wpkh) == "2NCGV4pFRiFc5449Psz2jeES3K3qCM6x1uk"
    assert bitzeny_test.p2wpkh_address(hash160_p2wpkh) == "tz1qfewhn63wyzfjca43vcc0zpwfq89wu6z6yavtql"
