# Copyright (c) 2020 zenywallet

when defined(js):
  import jsffi
  import jslib except Array
  import arraylib

  type
    Tx* = object
      handle*: JsObject

    Hash* {.borrow: `.`.} = distinct Array[byte]

  proc toHex*(x: Hash): cstring =
    var uint8Array = cast[Array[byte]](x).toUint8Array()
    result = uint8ArrayToHex(uint8Array.reverse())

  var TxMod = JsObject{}
  var Module: JsObject

  proc init*(module: JsObject) =
    Module = module
    TxMod.newTx = Module.cwrap("tx_newTx", NumVar, [].toJs)
    TxMod.toTx = Module.cwrap("tx_toTx", NumVar, [NumVar])
    TxMod.stripWitness = Module.cwrap("tx_stripWitness", NumVar, [NumVar])
    TxMod.txid = Module.cwrap("tx_txid", jsNull, [NumVar, NumVar])
    TxMod.hash = Module.cwrap("tx_hash", jsNull, [NumVar, NumVar])
    TxMod.free = Module.cwrap("tx_free", jsNull, [NumVar])
    TxMod.duplicate = Module.cwrap("tx_duplicate", NumVar, [NumVar])

  proc `=destroy`*(tx: var Tx) =
    if not tx.handle.isNil:
      TxMod.free(tx)
      tx.handle = jsNull

  proc `=copy`*(a: var Tx; b: Tx) =
    `=destroy`(a)
    if not b.handle.isNil:
      a.handle = TxMod.duplicate(b.handle)

  proc `=sink`*(a: var Tx; b: Tx) =
    `=destroy`(a)
    if not b.handle.isNil:
      a.handle = b.handle

  proc newTx*(): Tx =
    result.handle = TxMod.newTx()

  proc toTx*(data: Array[byte]): Tx =
    result.handle = TxMod.toTx(data.handle)

  proc stripWitness*(tx: Tx): Tx =
    result.handle = TxMod.stripWitness(tx)

  proc txid*(tx: Tx): Hash =
    result = newArray[byte]().Hash
    TxMod.txid(tx, result.handle)

  proc hash*(tx: Tx): Hash =
    result = newArray[byte]().Hash
    TxMod.hash(tx, result.handle)

else:
  when defined(emscripten):
    const EXPORTED_FUNCTIONS* = ["_tx_newTx", "_tx_toTx", "_tx_stripWitness", "_tx_txid", "_tx_hash", "_tx_free", "_tx_duplicate"]

  import sequtils, json
  import bytes, utils, reader, address, script
  import arraylib
  import custom
  import macros

  type
    Flags* = distinct uint8

    Witness* = distinct Array[byte]

    Sig* = distinct Array[byte]

    TxIn* = tuple[tx: Hash, n: uint32, sig: Sig, sequence: uint32]

    TxOut* = tuple[value: uint64, script: Script]

    TxObj* = object
      ver*: int32
      flags*: Flags
      ins*: Array[TxIn]
      outs*: Array[TxOut]
      witnesses*: Array[Array[Witness]]
      locktime*: uint32

    TxHandle* = ptr TxObj

    Tx* = object of HandleObj[TxHandle]

  const
    SIGHASH_ALL* = 1
    SIGHASH_NONE* = 2
    SIGHASH_SINGLE* = 3
    SIGHASH_ANYONECANPAY* = 0x80

    SIGHASH_DEFAULT* = 0
    SIGHASH_OUTPUT_MASK* = 3
    SIGHASH_INPUT_MASK* = 0x80

  proc free*(tx: Tx) {.exportc: "tx_$1".} =
    if tx.handle.isNil: return
    let tx = tx.handle
    `=destroy`(tx.witnesses)
    `=destroy`(tx.outs)
    `=destroy`(tx.ins)
    tx.deallocShared()

  proc `=destroy`*(tx: var Tx) = tx.free()

  proc `=copy`*(a: var Tx; b: Tx) =
    if a.handle == b.handle: return
    `=destroy`(a)
    wasMoved(a)
    if b.handle != nil:
      a.handle = cast[typeof(a.handle)](allocShared0(sizeof(TxObj)))
      a.handle.ver = b.handle.ver
      a.handle.flags = b.handle.flags
      a.handle.ins = b.handle.ins
      a.handle.outs = b.handle.outs
      a.handle.witnesses = b.handle.witnesses
      a.handle.locktime = b.handle.locktime

  proc `=sink`*(a: var Tx; b: Tx) =
    `=destroy`(a)
    wasMoved(a)
    a.handle = b.handle

  proc duplicate*(node: Tx): Tx =
    var h = cast[TxHandle](allocShared0(sizeof(TxObj)))
    h.ver = node.ver
    h.flags = node.flags
    h.ins = node.ins
    h.outs = node.outs
    h.witnesses = node.witnesses
    h.locktime = node.locktime
    result.handle = h

  proc duplicate*(node: Tx): Tx {.returnToHandle, exportc: "tx_duplicate".}

  proc toBytes*(flags: Flags): Array[byte] =
    var val = cast[uint8](flags)
    if val > 0:
      result = @^[byte 0, val]  # marker, flags

  proc toBytes*(data: Witness | Sig | Script): Array[byte] =
    var b = cast[Array[byte]](data)
    result = concat(varInt(b.len), b)

  proc toBytes*(datas: Array[TxIn] | Array[TxOut]): Array[byte] =
    if datas.len > 0:
      result = varInt(datas.len)
      for data in datas:
        result.add(data.toBytes)

  proc toBytes*(datas: Array[Witness]): Array[byte] =
    result = varInt(datas.len)
    for data in datas:
      result.add(data.toBytes)

  proc `$`*(tx: Tx): string = $tx.handle

  proc `$`*(data: Flags): string = $cast[uint8](data)

  proc `$`*(data: Sig): string =
    var sigBytes = cast[Array[byte]](data)
    try:
      var reader = newReader(sigBytes)
      var sigLen = reader.getVarInt
      var sig = reader.getBytes(sigLen - 1)
      var sigHashType = reader.getUint8()
      var pubLen = reader.getVarInt
      var pub = reader.getBytes(pubLen)
      result.add("(sigHash: " & $sig)
      if (sigHashType and SIGHASH_ALL.uint8) > 0:
        result.add(", sigHashType: SIGHASH_ALL")
      elif (sigHashType and SIGHASH_NONE.uint8) > 0:
        result.add(", sigHashType: SIGHASH_NONE")
      elif (sigHashType and SIGHASH_SINGLE.uint8) > 0:
        result.add(", sigHashType: SIGHASH_SINGLE")
      else:
        result.add(", sigHashType: Unknown")
      if (sigHashType and SIGHASH_ANYONECANPAY.uint8) > 0:
        result.add(" | SIGHASH_ANYONECANPAY")
      result.add(", pub: " & $pub & ")")
    except:
      result = $sigBytes

  proc `$`*(data: Witness): string = $cast[Array[byte]](data)

  const USE_SEQOFCAP_FOR_TX = true

  proc newTx*(): Tx =
    result.handle = cast[TxHandle](allocShared0(sizeof(TxObj)))

  proc newTx*(): Tx {.returnToHandle, exportc: "tx_newTx".}

  proc toTx*(reader: Reader): Tx =
    let tx = cast[TxHandle](allocShared0(sizeof(TxObj)))
    tx.ver = reader.getInt32
    var insLen = reader.getVarInt
    if insLen == 0:
      tx.flags = Flags(reader.getUint8)
      insLen = reader.getVarInt
    when USE_SEQOFCAP_FOR_TX:
      tx.ins = newArrayOfCap[TxIn](insLen)
    for i in 0..<insLen:
      let hash = Hash(reader.getBytes(32))
      let n = reader.getUint32
      let sigLen = reader.getVarInt
      tx.ins.add((hash, n, Sig(reader.getBytes(sigLen)), reader.getUint32))
    let outsLen = reader.getVarInt
    when USE_SEQOFCAP_FOR_TX:
      tx.outs = newArrayOfCap[TxOut](outsLen)
    for i in 0..<outsLen:
      let value = reader.getUint64
      let scriptLen = reader.getVarInt
      tx.outs.add((value, Script(reader.getBytes(scriptLen))))
    if tx.flags.uint8 == 1'u8:
      for i in 0..<insLen:
        let witnessLen = reader.getVarInt
        when USE_SEQOFCAP_FOR_TX:
          var witness = newArrayOfCap[Witness](witnessLen)
        else:
          var witness: Array[Witness]
        for j in 0..<witnessLen:
          let witnessSize = reader.getVarInt
          witness.add(Witness(reader.getBytes(witnessSize)))
        tx.witnesses.add(witness)
    tx.locktime = reader.getUint32
    result.handle = tx

  proc toTx*(data: Array[byte]): Tx {.inline.} =
    var reader = newReader(data)
    reader.toTx()

  proc toTx*(data: Array[byte]): Tx {.returnToHandle, exportc: "tx_toTx".}

  proc toTx*(data: ptr UncheckedArray[byte], size: int): Tx {.inline.} =
    var reader = newReader(data, size)
    reader.toTx()

  proc stripWitness(tx: Tx): Tx =
    var tx = cast[TxHandle](allocShared0(sizeof(TxObj)))
    tx.ver = tx.ver
    tx.ins = tx.ins
    tx.outs = tx.outs
    tx.locktime = tx.locktime
    result.handle = tx

  proc stripWitness(tx: Tx): Tx {.returnToHandle, exportc: "tx_stripWitness".}

  proc hash(data: Array[byte]): Hash = Hash(sha256d(data).toArray)

  proc txid*(tx: Tx): Hash {.inline.} = tx.stripWitness.toBytes.hash

  proc txid*(tx: Tx): Hash {.returnToLastParam, exportc: "tx_$1".}

  proc hash*(tx: Tx): Hash {.inline.} = tx.toBytes.hash

  proc hash*(tx: Tx): Hash {.returnToLastParam, exportc: "tx_$1".}

  proc hashBin(data: Array[byte]): Array[byte] = sha256d(data).toArray

  proc txidBin*(tx: Tx): Array[byte] = tx.stripWitness.toBytes.hashBin

  proc hashBin*(tx: Tx): Array[byte] = tx.toBytes.hashBin

  proc `%`*(o: Flags): JsonNode = newJInt(o.int)

  proc `%`*(o: Hash): JsonNode = newJString($o)

  proc `%`*(o: Witness | Sig | Script): JsonNode = newJString($o)

  proc `%`*(obj: TxIn | TxOut): JsonNode =
    result = newJObject()
    for key, val in obj.fieldPairs:
      when val is uint64:
        result[key] = val.toJson
      elif val is int64:
        result[key] = val.uint64.toJson
      else:
        var j = %val
        if j.kind != JNull:
          result[key] = %val

  proc `%`*[T](a: Array[T]): JsonNode = %a.toSeq

  proc `%`*(tx: Tx): JsonNode = %tx.handle[]

  proc toJson*(tx: Tx, network: Network): JsonNode =
    var json = %tx
    for i, o in tx.outs:
      var script = o.script
      json["outs"][i]["chunks"] = %script.getScriptChunks
      var addrs = network.getAddresses(script)
      if addrs.len > 0:
        json["outs"][i]["addrs"] = %addrs
    json


when isMainModule:
  # bitcoin-cli getblockhash 100000
  # bitcoin-cli getblock 0000281b28162fa5f7c1517cff694753f7d80c46bcbc56c60fb824790a8476c9
  # bitcoin-cli getrawtransaction b974686c0470b01241950a738f0751224a8ed7757f7e07f3fa5baaf11226ccca

  var txHexString = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff2003a08601049029065b0867ffffff000000000d2f6e6f64655374726174756d2fffffffff02d6e448c3050000001976a9149005c615a8cc2dfa5433bd7bf6ff4cd1cf345aa088acb2e0e60e000000001976a9145f618f9b2c116188ff1f8c6bf1923d0b6ad0da7988ac00000000"
  var tx = txHexString.toBytesFromHex.toTx
  echo tx
  echo tx.txid
  echo (%tx).pretty
  echo tx.toJson(getNetwork(NetworkId.BitZeny_testnet)).pretty

  # bitcoin-cli getrawtransaction 8ffd07492e2e79cb57cec39e2c6332c2dec5b604d444c2a3c1ceab5a8b672528 1
  var txHexString2 = "010000000262b19edba4c24d324e8ad1d62cb1525d5b3dafe5e92569308dc11411f93029d1010000006b483045022100cec911ccb594b8c83ec882ce014b0ab8b111754ab3ac4a494fef14dbb474e82202206057f679855e61b6743fa413847e5ed229fcb99a69bc316c9754bb4344221cf20121032abf381ba21c21a148fbf72225c5bbeaea7162c1a3db081c9f4c8577aa44f5defefffffffb9b95e5131644906bff25fcc59cd98b20279a26c902ac740965d3a04a122492000000006b48304502210085ad84f257cb088f0b6404785218fb45f9156ff99990cafa2e854b48f5a85a4302203edd39af5d4de57da7808a550e91391733e8e47a36515619f3d20e760218c3a501210330b8bc1309612641e04ecf5a294fffd6393e5e02fe72cd89035781caf628dde8feffffff044a7b3500000000001976a9140883084298f881c670d71cf2c0a014a25fc5a08388acd06461df040000001976a9142d079618f809d3a80d76b62fb900930916eb7b9688acf829776a000000001976a914ee02d26d68aa4763ed2bc4222581d4b127be46c288acf829776a000000001976a914a6ba7b15304fcb853e8c404d604e9d36f28bed0a88ac07520000"
  var tx2 = txHexString2.toBytesFromHex.toTx
  echo tx2
  echo tx2.txid
  echo (%tx2).pretty
  echo tx2.toJson(getNetwork(NetworkId.BitZeny_testnet)).pretty

  # bitcoin-cli getrawtransaction 23c52199e1759743d86ecf3a0d5fc6b4696ee41e2b47f6e85decaad0217f61f0
  var txHexString3 = "02000000000101c7350f8befa7ca3f01fc53b4d16fae0be40e69895bf5b9419ada520a2b841c8a0000000000fdffffff021861ec0e000000001600145f2d19df77167d62418f406bbcc3f6e868240406fcd5f50500000000160014424af8569bc5bc648fa139c05668bfe75f68bf770247304402205d25f465fe527be4ebc8f37eb5718ef12ff1183468c6c2e0e9f68655b7bbc93a02202a295bbe6db51439ab852b2a9f24a445bbec0cbfc232e153bea8157dbe982805012103ba08cb88b0d5e719c50676663dce904041c53a234820fa6f2d56fbc9cd2dda9691710000"
  var tx3 = txHexString3.toBytesFromHex.toTx
  echo tx3
  echo tx3.txid
  echo tx3.hash
  echo (%tx3).pretty
  echo tx3.toBytes
  echo tx3.toJson(getNetwork(NetworkId.BitZeny_testnet)).pretty
