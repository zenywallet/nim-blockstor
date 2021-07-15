# Copyright (c) 2020 zenywallet

import sophia, bytes, json
import blocks

type Prefix* {.pure.} = enum
  params = 0  # param_id = value
  blocks      # height = hash, time, start_id
  txs         # txid = height, id, (skip)
  ids         # id = txid
  txouts      # id, n = value, address_hash, address_type
  unspents    # address_hash, id, n = value
  addrvals    # address_hash, (address_type) = value, utxo_count
  addrlogs    # address_hash, id, trans (0 - out | 1 - in) = value, address_type
  minedids    # id = height

type
  DbStatus* {.pure.} = enum
    Success = 0
    Error
    NotFound

  DbResult*[T] = object
    case err*: DbStatus
    of DbStatus.Success:
      res*: T
    of DbStatus.Error:
      discard
    of DbStatus.NotFound:
      discard

  DbInst* = distinct Sophia
  DbInsts* = seq[DbInst]

converter toSophia*(dbInst: DbInst): Sophia = dbInst.Sophia
converter toDbInst*(sophia: Sophia): DbInst = sophia.DbInst
converter toDbInsts*(sophias: seq[Sophia]): DbInsts = sophias.DbInsts

proc open*(datapath: string): DbInst =
  var dbInst = new Sophia
  dbInst.open(datapath)
  dbInst

proc open*(dbpath, dbname: string): DbInst =
  var dbInst = new Sophia
  dbInst.open(dbpath, dbname)
  dbInst

proc opens*(dbpath: string, dbnames: seq[string]): DbInsts = sophia.opens(dbpath, dbnames)

proc close*(dbInst: DbInst) =
  sophia.close(dbInst)

proc close*(dbInsts: DbInsts) =
  sophia.close(cast[seq[Sophia]](dbInsts))

proc backupRun*(dbInst: DbInst) =
  sophia.backupRun(dbInst)

proc backupRun*(dbInsts: DbInsts) =
  sophia.backupRun(dbInsts[0])

proc setBlockHash*(db: DbInst, height: int, hash: BlockHash, time: uint32, start_id: uint64) =
  let key = BytesBE(Prefix.blocks, height.uint32)
  let val = BytesBE(hash, time, start_id)
  db.put(key, val)

type
  BlockHashResult* = tuple[hash: BlockHash, time: uint32, start_id: uint64]
  DbBlockHashResult* = DbResult[BlockHashResult]

proc getBlockHash*(db: DbInst, height: int): DbBlockHashResult =
  let key = BytesBE(Prefix.blocks, height.uint32)
  let d = db.get(key)
  if d.len == 44:
    var d = d
    let hash = BlockHash(d[0..31])
    let time = d[32].toUint32BE
    let start_id = d[36].toUint64BE
    result = DbBlockHashResult(err: DbStatus.Success, res: (hash, time, start_id))
  else:
    result = DbBlockHashResult(err: DbStatus.NotFound)

type
  LastBlockHashResult* = tuple[height: int, hash: BlockHash, time: uint32, start_id: uint64]
  DbLastBlockHashResult* = DbResult[LastBlockHashResult]

proc getLastBlockHash*(db: DbInst): DbLastBlockHashResult =
  var startkey = BytesBE(Prefix.blocks, uint32.high)
  var endkey = BytesBE(Prefix.blocks, uint32.low)

  for d in db.getsRev(startkey, endkey):
    if d.key.len == 5 and d.val.len == 44:
      var d = d
      let height = d.key[1].toUint32BE.int
      let hash = BlockHash(d.val[0..31])
      let time = d.val[32].toUint32BE
      let start_id = d.val[36].toUint64BE
      return DbLastBlockHashResult(err: DbStatus.Success, res: (height, hash, time, start_id))
    break
  return DbLastBlockHashResult(err: DbStatus.NotFound)

proc delBlockHash*(db: DbInst, height: int) =
  let key = BytesBE(Prefix.blocks, height.uint32)
  db.del(key)

proc setTx*(db: DbInst, txid: Hash, height: int, id: uint64, skip: uint8 = 0) =
  let key = BytesBE(Prefix.txs, txid)
  let val = BytesBE(height.uint32, id, skip.uint8)
  db.put(key, val)

type
  TxResult* = tuple[height: int, id: uint64, skip: uint8]
  DbTxResult* = DbResult[TxResult]

proc getTx*(db: DbInst, txid: Hash): DbTxResult =
  let key = BytesBE(Prefix.txs, txid)
  let d = db.get(key)
  if d.len == 13:
    var d = d
    let height = d[0].toUint32BE.int
    let id = d[4].toUint64BE
    let skip = d[12].uint8
    result = DbTxResult(err: DbStatus.Success, res: (height, id, skip))
  else:
    result = DbTxResult(err: DbStatus.NotFound)

proc delTx*(db: DbInst, txid: Hash) =
  let key = BytesBE(Prefix.txs, txid)
  db.del(key)

proc setId*(db: DbInst, id: uint64, txid: Hash) =
  let key = BytesBE(Prefix.ids, id)
  let val = BytesBE(txid)
  db.put(key, val)

type
  IdResult* = Hash
  DbIdResult* = DbResult[IdResult]

proc getId*(db: DbInst, id: uint64): DbIdResult =
  let key = BytesBE(Prefix.ids, id)
  let d = db.get(key)
  if d.len >= 32:
    var d = d
    let txid = d[0].toHash
    result = DbIdResult(err: DbStatus.Success, res: txid)
  else:
    result = DbIdResult(err: DbStatus.NotFound)

proc delId*(db: DbInst, id: uint64) =
  let key = BytesBE(Prefix.ids, id)
  db.del(key)

proc setTxout*(db: DbInst, id: uint64, n: uint32,
              value: uint64, address_hash: Hash160, address_type: uint8) =
  let key = BytesBE(Prefix.txouts, id, n)
  let val = BytesBE(value, address_hash, address_type)
  db.put(key, val)

type
  TxoutResult* = tuple[value: uint64, address_hash: Hash160, address_type: uint8]
  DbTxoutResult* = DbResult[TxoutResult]

proc getTxout*(db: DbInst, id: uint64, n: uint32): DbTxoutResult =
  let key = BytesBE(Prefix.txouts, id, n)
  let d = db.get(key)
  if d.len == 29:
    var d = d
    let value = d[0].toUint64BE
    let address_hash = d[8].toHash160
    let address_type = d[28]
    result = DbTxoutResult(err: DbStatus.Success, res: (value, address_hash, address_type))
  elif d.len == 9:
    var d = d
    let value = d[0].toUint64BE
    let address_type = d[^1]
    result = DbTxoutResult(err: DbStatus.Success, res: (value, Hash160(@[]), address_type))
  else:
    result = DbTxoutResult(err: DbStatus.NotFound)

type
  TxoutsResult* = tuple[n: uint32, value: uint64, address_hash: Hash160, address_type: uint8]

iterator getTxouts*(db: DbInst, id: uint64): TxoutsResult =
  let key = BytesBE(Prefix.txouts, id)
  for d in db.gets(key):
    if d.key.len != 13:
      continue
    if d.val.len == 29:
      var d = d
      let n = d.key[8].toUint32BE
      let value = d.val[0].toUint64BE
      let address_hash = d.val[8].toHash160
      let address_type = d.val[28]
      yield (n, value, address_hash, address_type)
    elif d.val.len == 9:
      var d = d
      let n = d.key[8].toUint32BE
      let value = d.val[0].toUint64BE
      let address_hash = Hash160(@[])
      let address_type = d.val[^1]
      yield (n, value, address_hash, address_type)

proc delTxout*(db: DbInst, id: uint64, n: uint32) =
  let key = BytesBE(Prefix.txouts, id, n)
  db.del(key)

proc setUnspent*(db: DbInst, address_hash: Hash160, id: uint64,
                n: uint32, value: uint64) =
  let key = BytesBE(Prefix.unspents, address_hash, id, n)
  let val = BytesBE(value)
  db.put(key, val)

type
  UnspentResult* = uint64
  DbUnspentResult* = DbResult[UnspentResult]

proc getUnspent*(db: DbInst, address_hash: Hash160, id: uint64,
                n: uint32): DbUnspentResult =
  let key = BytesBE(Prefix.unspents, address_hash, id, n)
  let d = db.get(key)
  if d.len == 8:
    var d = d
    let value = d[0].toUint64BE
    result = DbUnspentResult(err: DbStatus.Success, res: value)
  else:
    result = DbUnspentResult(err: DbStatus.NotFound)

type
  UnspentsResult* = tuple[id: uint64, n: uint32, value: uint64]

iterator getUnspents*(db: DbInst, address_hash: Hash160,
                    options: tuple = ()): UnspentsResult =
  var low_id: uint64 = uint64.low
  var high_id: uint64 = uint64.high
  var rev_flag = false

  for key, val in options.fieldPairs:
    case key
    of "gte":
      low_id = val.uint64
    of "gt":
      if val.uint64 == uint64.high:
        raise
      low_id = val.uint64 + 1'u64
    of "lte":
      high_id = val.uint64
    of "lt":
      if val.uint64 == uint64.low:
        raise
      high_id = val.uint64 - 1'u64
    of "rev":
      if val.uint64 > uint64.low:
        rev_flag = true

  if rev_flag:
    var startkey = BytesBE(Prefix.unspents, address_hash, high_id)
    var endkey = BytesBE(Prefix.unspents, address_hash, low_id)
    for d in db.getsRev(startkey, endkey):
      if d.key.len != 33 or d.val.len != 8:
        break
      var d = d
      let id = d.key[^12].toUint64BE
      let n = d.key[^4].toUint32BE
      let value = d.val[0].toUint64BE
      yield (id, n, value)
  else:
    var startkey = BytesBE(Prefix.unspents, address_hash, low_id)
    var endkey = BytesBE(Prefix.unspents, address_hash, high_id)
    for d in db.gets(startkey, endkey):
      if d.key.len != 33 or d.val.len != 8:
        break
      var d = d
      let id = d.key[^12].toUint64BE
      let n = d.key[^4].toUint32BE
      let value = d.val[0].toUint64BE
      yield (id, n, value)

proc delUnspent*(db: DbInst, address_hash: Hash160, id: uint64,
                n: uint32) =
  let key = BytesBE(Prefix.unspents, address_hash, id, n)
  db.del(key)

proc setAddrval*(db: DbInst, address_hash: Hash160, value: uint64, utxo_count: uint32) =
  let key = BytesBE(Prefix.addrvals, address_hash)
  let val = BytesBE(value, utxo_count)
  db.put(key, val)

type
  AddrvalResult* = tuple[value: uint64, utxo_count: uint32]
  DbAddrvalResult* = DbResult[AddrvalResult]

proc getAddrval*(db: DbInst, address_hash: Hash160): DbAddrvalResult =
  let key = BytesBE(Prefix.addrvals, address_hash)
  let d = db.get(key)
  if d.len >= 12:
    var d = d
    let value = d[0].toUint64BE
    let utxo_count = d[8].toUint32BE
    result = DbAddrvalResult(err: DbStatus.Success, res: (value, utxo_count))
  else:
    result = DbAddrvalResult(err: DbStatus.NotFound)

proc delAddrval*(db: DbInst, address_hash: Hash160) =
  let key = BytesBE(Prefix.addrvals, address_hash)
  db.del(key)

proc setAddrlog*(db: DbInst, address_hash: Hash160, id: uint64,
                trans: uint8, value: uint64, address_type: uint8) =
  let key = BytesBE(Prefix.addrlogs, address_hash, id, trans)
  let val = BytesBE(value, address_type)
  db.put(key, val)

type
  AddrlogResult* = tuple[value: uint64, address_type: uint8]
  DbAddrlogResult* = DbResult[AddrlogResult]

proc getAddrlog*(db: DbInst, address_hash: Hash160, id: uint64,
                trans: uint8): DbAddrlogResult =
  let key = BytesBE(Prefix.addrlogs, address_hash, id, trans)
  let d = db.get(key)
  if d.len == 9:
    var d = d
    let value = d[0].toUint64BE
    let address_type = d[8]
    result = DbAddrlogResult(err: DbStatus.Success, res: (value, address_type))
  else:
    result = DbAddrlogResult(err: DbStatus.NotFound)

type
  AddrlogsResult* = tuple[id: uint64, trans: uint8, value: uint64, address_type: uint8]

iterator getAddrlogs*(db: DbInst, address_hash: Hash160,
                    options: tuple = ()): AddrlogsResult =
  var low_id: uint64 = uint64.low
  var high_id: uint64 = uint64.high
  var rev_flag = false

  for key, val in options.fieldPairs:
    case key
    of "gte":
      low_id = val.uint64
    of "gt":
      if val.uint64 == uint64.high:
        raise
      low_id = val.uint64 + 1'u64
    of "lte":
      high_id = val.uint64
    of "lt":
      if val.uint64 == uint64.low:
        raise
      high_id = val.uint64 - 1'u64
    of "rev":
      if val.uint64 > uint64.low:
        rev_flag = true

  if rev_flag:
    var startkey = BytesBE(Prefix.addrlogs, address_hash, high_id)
    var endkey = BytesBE(Prefix.addrlogs, address_hash, low_id)
    for d in db.getsRev(startkey, endkey):
      if d.key.len != 30 or d.val.len != 9:
        break
      var d = d
      let id = d.key[^9].toUint64BE
      let trans = d.key[^1]
      let value = d.val[0].toUint64BE
      let address_type = d.val[8]
      yield (id, trans, value, address_type)
  else:
    var startkey = BytesBE(Prefix.addrlogs, address_hash, low_id)
    var endkey = BytesBE(Prefix.addrlogs, address_hash, high_id)
    for d in db.gets(startkey, endkey):
      if d.key.len != 30 or d.val.len != 9:
        break
      var d = d
      let id = d.key[^9].toUint64BE
      let trans = d.key[^1]
      let value = d.val[0].toUint64BE
      let address_type = d.val[8]
      yield (id, trans, value, address_type)

proc delAddrlog*(db: DbInst, address_hash: Hash160, id: uint64,
                trans: uint8) =
  let key = BytesBE(Prefix.addrlogs, address_hash, id, trans)
  db.del(key)

proc setMinedId*(db: DbInst, id: uint64, height: int) =
  let key = BytesBE(Prefix.minedids, id)
  let val = BytesBE(height.uint32)
  db.put(key, val)

type
  MinedIdResult* = int
  DbMinedIdResult* = DbResult[MinedIdResult]

proc getMinedId*(db: DbInst, id: uint64): DbMinedIdResult =
  let key = BytesBE(Prefix.minedids, id)
  let d = db.get(key)
  if d.len == 4:
    var d = d
    let height = d[0].toUint32BE.int
    result = DbMinedIdResult(err: DbStatus.Success, res: height)
  else:
    result = DbMinedIdResult(err: DbStatus.NotFound)

proc delMinedId*(db: DbInst, id: uint64) =
  let key = BytesBE(Prefix.minedids, id)
  db.del(key)


when isMainModule:
  import sequtils

  var db = open("data_test/block")

  proc quit() {.noconv.} =
    db.close()

  addQuitProc(quit)

  var address_hash0: array[20, byte]
  for i in 0..<20:
    address_hash0[i] = i.byte
  var address_hash = Hash160(address_hash0.toSeq)

  db.setUnspent(address_hash, 0'u64, 0'u32, 39'u64)
  db.setUnspent(address_hash, 0xffffffffffffffff'u64, 0xffffffff'u32, 39'u64)
  db.setUnspent(address_hash, 0xffffffffffffffff'u64, 0'u32, 39'u64)
  db.setUnspent(address_hash, 0'u64, 0xffffffff'u32, 39'u64)

  for d in db.getUnspents(address_hash, ()):
    echo d
  echo "-----"
  for d in db.getUnspents(address_hash, (gte: 0)):
    echo d
  echo "-----"
  for d in db.getUnspents(address_hash, (gt: 0, lte: 0xffffffffffffffff'u64)):
    echo d
  echo "-----"
  for d in db.getUnspents(address_hash, (gt: 0, lt: 0xffffffffffffffff'u64)):
    echo d
  echo "-----"
  for d in db.getUnspents(address_hash, (gte: 0, lt: 0xffffffffffffffff'u64)):
    echo d
  echo "-----"
  for d in db.getUnspents(address_hash, (gte: 0'u64, lte: 0xffffffffffffffff'u64, rev: 1)):
    echo d
  echo "-----"
  for d in db.gets(BytesBE(Prefix.unspents, address_hash)):
    echo d
