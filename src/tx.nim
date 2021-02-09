# Copyright (c) 2020 zenywallet

import sequtils, json, algorithm
import bytes, utils, reader, address, script

type
  Flags* = distinct uint8

  Witness* = distinct seq[byte]

  Sig* = distinct seq[byte]

  TxIn* = tuple[tx: Hash, n: uint32, sig: Sig, sequence: uint32]

  TxOut* = tuple[value: uint64, script: Script]

  Tx* = ref object
    ver*: int32
    flags*: Flags
    ins*: seq[TxIn]
    outs*: seq[TxOut]
    witnesses*: seq[Witness]
    locktime*: uint32


proc toBytes*(flags: Flags): seq[byte] =
  var val = cast[uint8](flags)
  if val > 0:
    result = @[byte 0, val]  # marker, flags

proc toBytes*(data: Witness | Sig | Script): seq[byte] =
  var b = cast[seq[byte]](data)
  result = concat(varInt(b.len), b)

proc toBytes*(datas: seq[Witness] | seq[TxIn] | seq[TxOut]): seq[byte] =
  if datas.len > 0:
    result = varInt(datas.len)
    for data in datas:
      result.add(data.toBytes)

proc `$`*(data: Flags): string = $cast[uint8](data)

proc `$`*(data: Witness | Sig | Script): string = $cast[seq[byte]](data)

proc toTx*(reader: Reader): Tx =
  var tx = new Tx
  tx.ver = reader.getInt32
  var insLen = reader.getVarInt
  if insLen == 0:
    tx.flags = Flags(reader.getUint8)
    insLen = reader.getVarInt
  for i in 0..<insLen:
    var hash = Hash(reader.getBytes(32))
    var n = reader.getUint32
    var sigLen = reader.getVarInt
    tx.ins.add((hash, n, Sig(reader.getBytes(sigLen)), reader.getUint32))
  var outsLen = reader.getVarInt
  for i in 0..<outsLen:
    var value = reader.getUint64
    var scriptLen = reader.getVarInt
    tx.outs.add((value, Script(reader.getBytes(scriptLen))))
  if tx.flags.uint8 == 1'u8:
    var witnessLen = reader.getVarInt
    for i in 0..<witnessLen:
      var witnessSize = reader.getVarInt
      tx.witnesses.add(Witness(reader.getBytes(witnessSize)))
  tx.locktime = reader.getUint32
  tx

proc toTx*(data: seq[byte]): Tx =
  var reader = newReader(data)
  reader.toTx()

proc stripWitness(tx: Tx): Tx =
  Tx(ver: tx.ver,
    ins: tx.ins,
    outs: tx.outs,
    locktime: tx.locktime)

proc hash(data: seq[byte]): Hash = Hash(sha256d(data).toSeq)

proc txid*(tx: Tx): Hash = tx.stripWitness.toBytes.hash

proc hash*(tx: Tx): Hash = tx.toBytes.hash

proc hashBin(data: seq[byte]): seq[byte] = sha256d(data).toSeq

proc txidBin*(tx: Tx): seq[byte] = tx.stripWitness.toBytes.hashBin

proc hashBin*(tx: Tx): seq[byte] = tx.toBytes.hashBin

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

proc toJson*(tx: Tx, network: Network): JsonNode =
  var json = %tx
  for i, w in tx.witnesses:
    json["ins"][i]["witness"] = %w
  json.delete("witnesses")
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
