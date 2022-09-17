# Copyright (c) 2020 zenywallet

import sequtils, json
import tx, bytes, reader, address, script, utils

type
  BlockHash* = distinct seq[byte]

  MerkleHash* = distinct seq[byte]

  BlockHeader* = ref object
    ver*: int32
    prev*: BlockHash
    merkle*: MerkleHash
    time*: uint32
    bits*: uint32
    nonce*: uint32

  Block* = ref object
    header*: BlockHeader
    txn*: VarInt
    txs*: seq[Tx]

  BlockRaw* = ref object
    magic: uint32
    size: uint32
    blk: Block

  BlockHashObj* = distinct array[32, byte]

  MerkleHashObj* = distinct array[32, byte]

  BlockHeaderObj* = object
    ver*: int32
    prev*: BlockHashObj
    merkle*: MerkleHashObj
    time*: uint32
    bits*: uint32
    nonce*: uint32

proc toBytes*(o: BlockHash | MerkleHash): seq[byte] {.inline.} = cast[seq[byte]](o)
proc toBytesBE*(o: BlockHash | MerkleHash): seq[byte] {.inline.} = cast[seq[byte]](o)
proc toBytes*(o: BlockHashObj | MerkleHashObj): seq[byte] {.inline.} = cast[array[32, byte]](o).toBytes
proc toBytesBE*(o: BlockHashObj | MerkleHashObj): seq[byte] {.inline.} = cast[array[32, byte]](o).toBytes

proc toBytes*(o: seq[Tx]): seq[byte] {.inline.} =
  var s: seq[seq[byte]]
  for i in o:
    s.add(i.toBytes)
  result = concat(s)

proc toBlockHash*(x: Hex): BlockHash {.inline.} = x.toBytes.toReverse.BlockHash

proc `$`*(o: BlockHash | MerkleHash): string = $toReverse(cast[seq[byte]](o))

proc `$`*(o: BlockHashObj | MerkleHashObj): string = $toReverse(o.toBytes)

proc toHeader*(reader: Reader): BlockHeader =
  var header = new BlockHeader
  header.ver = reader.getInt32
  header.prev = BlockHash(reader.getBytes(32))
  header.merkle = MerkleHash(reader.getBytes(32))
  header.time = reader.getUint32
  header.bits = reader.getUint32
  header.nonce = reader.getUint32
  result = header

proc toHeader*(data: seq[byte]): BlockHeader {.inline.} =
  var reader = newReader(data)
  reader.toHeader()

proc toBlock*(reader: Reader): Block =
  var b = new Block
  b.header = new BlockHeader
  b.header.ver = reader.getInt32
  b.header.prev = BlockHash(reader.getBytes(32))
  b.header.merkle = MerkleHash(reader.getBytes(32))
  b.header.time = reader.getUint32
  b.header.bits = reader.getUint32
  b.header.nonce = reader.getUint32
  b.txn = VarInt(reader.getVarInt)
  for i in 0..<b.txn.int:
    b.txs.add(reader.toTx)
  result = b

proc toBlock*(data: seq[byte]): Block {.inline.} =
  var reader = newReader(data)
  reader.toBlock()

proc toBlock*(data: ptr UncheckedArray[byte], size: int): Block {.inline.} =
  var reader = newReader(data, size)
  reader.toBlock()

proc `%`*(o: BlockHash | MerkleHash): JsonNode = newJString($toReverse(cast[seq[byte]](o)))

proc `%`*(o: BlockHashObj | MerkleHashObj): JsonNode = newJString($toReverse(o.toBytes))

proc `%`*(o: VarInt): JsonNode = o.uint64.toJson

proc toJson*(blk: Block, network: Network): JsonNode =
  var json = %blk
  for i, tx in blk.txs:
    for j, o in tx.outs:
      var script = o.script
      var p = json["txs"][i]["outs"][j]
      var chunks = script.getScriptChunks
      p["chunks"] = %chunks
      p["addrs"] = %network.getAddresses(chunks)
  json

proc merkle*(txids: seq[seq[byte]]): MerkleHash =
  var list = txids
  while list.len > 1:
    var tmplist: seq[seq[byte]]
    for i in countup(0, list.len - 2, 2):
      tmplist.add(sha256d(concat(list[i], list[i + 1])).toSeq)
    if list.len mod 2 == 1:
      tmplist.add(sha256d(concat(list[^1], list[^1])).toSeq)
    list = tmplist
  result = MerkleHash(list[0])

proc `==`*(x, y: BlockHash | MerkleHash): bool = x.toBytes == y.toBytes


when isMainModule:
  # bitcoin-cli getblockhash 100000
  # bitcoin-cli getblock 0000281b28162fa5f7c1517cff694753f7d80c46bcbc56c60fb824790a8476c9 0

  var blockRawString = "00000020de93bcdf1710e4424602346c4a6df4b2ff9d49e9a2674e463f557eddfe2b0000a459c4a535f3c54073278176213f387322a5daef576f97b5d8a83eccde5c34008f29065bffff3f1e4000052c0201000000010000000000000000000000000000000000000000000000000000000000000000ffffffff2003a08601049029065b0867ffffff000000000d2f6e6f64655374726174756d2fffffffff02d6e448c3050000001976a9149005c615a8cc2dfa5433bd7bf6ff4cd1cf345aa088acb2e0e60e000000001976a9145f618f9b2c116188ff1f8c6bf1923d0b6ad0da7988ac000000000100000002425ecdca0061015ce78405497dfd74415e1ef620821fa595d3a805baa4c3713d030000006a4730440220140b235480671842fde415fe588bf278734c15c038d410ed2f2c1a974b454c1102201084b6c5fda777eff8ef6b6c9c21f1d351797c04be3221ae114095acde43933d0121021105dfb3bff38bc41b4f565cc52c521ef9cbfd5c1aa16133d6964b7755228aeffeffffff8f44863d2173d527059eec71186167fec4ee829fa48ec81cbcef0767cefee8c1000000006b483045022100c7776c5ff618155dfcc1fc97fa986bc0e809ac4c7e808612f5e6eadf65bfc5db022010ffe4501eeb9cba37eef233c696eae94a52d0fc74fdcdd69a9bb191523bf4bf012102c3a59ea9b283839b61ff1840f097c77e487ca704383c428da17f1e21678da638feffffff04d86b6146020000001976a9149dde90de5bed84ca64ca53cbadcb552ae562522e88ac943f2613010000001976a914adc2e95df7bda84325585cc1fe5ff58c02f1806688ac96e4bf00000000001976a914eb44cd98efdcf0b1a6f972bd61a805b2efa20db188ac0b97c069020000001976a914612bba6f63c6ade789938bff79cd91a48d2b483a88ac9f860100"

  var blk = blockRawString.Hex.toBytes.toBlock
  echo blk
  echo (%blk).pretty
  echo blk.toJson(getNetwork(NetworkId.BitZeny_testnet)).pretty

  var tx1 = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff2003a08601049029065b0867ffffff000000000d2f6e6f64655374726174756d2fffffffff02d6e448c3050000001976a9149005c615a8cc2dfa5433bd7bf6ff4cd1cf345aa088acb2e0e60e000000001976a9145f618f9b2c116188ff1f8c6bf1923d0b6ad0da7988ac00000000"

  var tx2 = "0100000002425ecdca0061015ce78405497dfd74415e1ef620821fa595d3a805baa4c3713d030000006a4730440220140b235480671842fde415fe588bf278734c15c038d410ed2f2c1a974b454c1102201084b6c5fda777eff8ef6b6c9c21f1d351797c04be3221ae114095acde43933d0121021105dfb3bff38bc41b4f565cc52c521ef9cbfd5c1aa16133d6964b7755228aeffeffffff8f44863d2173d527059eec71186167fec4ee829fa48ec81cbcef0767cefee8c1000000006b483045022100c7776c5ff618155dfcc1fc97fa986bc0e809ac4c7e808612f5e6eadf65bfc5db022010ffe4501eeb9cba37eef233c696eae94a52d0fc74fdcdd69a9bb191523bf4bf012102c3a59ea9b283839b61ff1840f097c77e487ca704383c428da17f1e21678da638feffffff04d86b6146020000001976a9149dde90de5bed84ca64ca53cbadcb552ae562522e88ac943f2613010000001976a914adc2e95df7bda84325585cc1fe5ff58c02f1806688ac96e4bf00000000001976a914eb44cd98efdcf0b1a6f972bd61a805b2efa20db188ac0b97c069020000001976a914612bba6f63c6ade789938bff79cd91a48d2b483a88ac9f860100"

  var h = new BlockHeader
  h.ver = 536870912'i32
  h.prev = BlockHash("00002bfedd7e553f464e67a2e9499dffb2f46d4a6c34024642e41017dfbc93de".Hex.toBytes.toReverse)
  #h.merkle = MerkleHash("00345cdecc3ea8d8b5976f57efdaa52273383f217681277340c5f335a5c459a4".Hex.toBytes.toReverse)
  h.merkle = merkle(@[tx1.Hex.toBytes.toTx.txidBin, tx2.Hex.toBytes.toTx.txidBin])
  h.time = 1527130511'u32
  h.bits = 0x1e3fffff'u32
  h.nonce = 738525248'u32

  var b = new Block
  b.header = h
  b.txn = VarInt(2)
  b.txs.add(tx1.Hex.toBytes.toTx)
  b.txs.add(tx2.Hex.toBytes.toTx)

  assert b.toBytes.toHex == blockRawString
