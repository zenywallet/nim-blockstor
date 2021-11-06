# Copyright (c) 2021 zenywallet

import os, times, tables
import bytes, rpc, tcp, db, utils
import address, script, blocks, tx
import algorithm
import sequtils, strutils
import ptlock
import json
import uthash
export uthash

# spents - address_hash = address_type, txid, n, value, txid_out
# txouts - address_hash = address_type, txid, n, value
# txaddrs - txid = address_hash, address_type, trans (0 - out | 1 - in), val
# txtxouts - txid = n, value, address_hash, address_type
# txspents - txid_out = txid, n, value, address_hash, address_type
# unconfs - address_hash, address_type = val_out, val_in

type
  HashArray* = array[32, byte]
  Hash160Array* = array[20, byte]

  MempoolAddrSpentObj* = object
    # address_hash*: Hash160Array - key
    address_type*: AddressType
    txid*: HashArray
    n*: uint32
    value*: uint64
    txid_out*: HashArray

  MempoolAddrTxoutObj* = object
    # address_hash*: Hash160Array - key
    address_type*: AddressType
    txid*: HashArray
    n*: uint32
    value*: uint64

  MempoolTxAddrObj* = object
    # txid*: HashArray - key
    address_hash*: Hash160Array
    address_type*: AddressType
    trans*: uint8
    value*: uint64

  MempoolTxTxoutObj* = object
    # txid: HashArray - key
    n*: uint32
    value*: uint64
    address_hash*: Hash160Array
    address_type*: AddressType

  MempoolTxSpentObj* = object
    # txid_out: HashArray - key
    txid*: HashArray
    n*: uint32
    value*: uint64
    address_hash*: Hash160Array
    address_type*: AddressType

  MempoolUnconfObj* = object
    # address_hash*: Hash160Array - key
    # address_type*: AddressType - key
    value_out*: uint64
    value_in*: uint64

  MempoolAddrSpent* = ptr MempoolAddrSpentObj
  MempoolAddrTxout* = ptr MempoolAddrTxoutObj

  MempoolTxAddr* = ptr MempoolTxAddrObj
  MempoolTxTxout* = ptr MempoolTxTxoutObj
  MempoolTxSpent* = ptr MempoolTxSpentObj

  MempoolUnconf* = ptr MempoolUnconfObj

  MempoolError* = object of CatchableError


template debug(x: varargs[string, `$`]) {.used.} = echo join(x)
template info(x: varargs[string, `$`]) {.used.} = echo join(x)
template error(x: varargs[string, `$`]) {.used.} = echo join(x)

proc toFixedHash160(h: Hash160): Hash160 =
  var s = h.toBytes
  if s.len == 20:
    result = h
  elif s.len < 20:
    let padLen = 20 - s.len
    result = (s, Pad(padLen)).toBytes.Hash160
  else:
    raise newException(MempoolError, "length is too large len=" & $s.len)

proc newMempoolAddrSpent(address_type: AddressType, txid: Hash, n: uint32,
                        value: uint64, txid_out: Hash): MempoolAddrSpent =
  let p = cast[MempoolAddrSpent](allocShared0(sizeof(MempoolAddrSpentObj)))
  p.address_type = address_type
  let txidSeq = cast[seq[byte]](txid)
  if txidSeq.len != 32:
    raise newException(MempoolError, "invalid txid")
  copyMem(addr p.txid, unsafeAddr txidSeq[0], sizeof(HashArray))
  p.n = n
  p.value = value
  let txidOutSeq = cast[seq[byte]](txid_out)
  if txidOutSeq.len != 32:
    raise newException(MempoolError, "invalid txid_out")
  copyMem(addr p.txid_out, unsafeAddr txidOutSeq[0], sizeof(HashArray))
  result = p

proc newMempoolAddrTxout(address_type: AddressType, txid: Hash, n: uint32,
                        value: uint64): MempoolAddrTxout =
  let p = cast[MempoolAddrTxout](allocShared0(sizeof(MempoolAddrTxoutObj)))
  p.address_type = address_type
  let txidSeq = cast[seq[byte]](txid)
  if txidSeq.len != 32:
    raise newException(MempoolError, "invalid txid")
  copyMem(addr p.txid, unsafeAddr txidSeq[0], sizeof(HashArray))
  p.n = n
  p.value = value
  result = p

proc newMempoolTxAddr(address_hash: Hash160, address_type: AddressType,
                      trans: uint8, value: uint64): MempoolTxAddr =
  let p = cast[MempoolTxAddr](allocShared0(sizeof(MempoolTxAddrObj)))
  let ahash = cast[seq[byte]](address_hash)
  if ahash.len != 20:
    raise newException(MempoolError, "invalid address_hash txaddr")
  copyMem(addr p.address_hash, unsafeAddr ahash[0], sizeof(Hash160Array))
  p.address_type = address_type
  p.trans = trans
  p.value = value
  result = p

proc newMempoolTxTxout(n: uint32, value: uint64, address_hash: Hash160,
                      address_type: AddressType): MempoolTxTxout =
  let p = cast[MempoolTxTxout](allocShared0(sizeof(MempoolTxTxoutObj)))
  p.n = n
  p.value = value
  let ahash = cast[seq[byte]](address_hash)
  if ahash.len != 20:
    raise newException(MempoolError, "invalid address_hash txtxout")
  copyMem(addr p.address_hash, unsafeAddr ahash[0], sizeof(Hash160Array))
  p.address_type = address_type
  result = p

proc newMempoolTxSpent(txid: Hash, n: uint32, value: uint64, address_hash: Hash160,
                      address_type: AddressType): MempoolTxSpent =
  let p = cast[MempoolTxSpent](allocShared0(sizeof(MempoolTxSpentObj)))
  let txidSeq = cast[seq[byte]](txid)
  if txidSeq.len != 32:
    raise newException(MempoolError, "invalid txid")
  copyMem(addr p.txid, unsafeAddr txidSeq[0], sizeof(HashArray))
  p.n = n
  p.value = value
  let ahash = cast[seq[byte]](address_hash)
  if ahash.len != 20:
    raise newException(MempoolError, "invalid address_hash txspent")
  copyMem(addr p.address_hash, unsafeAddr ahash[0], sizeof(Hash160Array))
  p.address_type = address_type
  result = p

proc newMempoolUnconf(value_out: uint64, value_in: uint64): MempoolUnconf =
  let p = cast[MempoolUnconf](allocShared0(sizeof(MempoolUnconfObj)))
  p.value_out = value_out
  p.value_in = value_in
  result = p

proc freeVal[T](val: T) =
  when T is MempoolAddrSpent |
            MempoolAddrTxout |
            MempoolTxAddr |
            MempoolTxTxout |
            MempoolTxSpent |
            MempoolUnconf:
    val.deallocShared()
  else:
    discard

proc `$`*(data: HashArray | Hash160Array): string =
  var b = data.toSeq
  algorithm.reverse(b)
  bytes.toHex(b)

loadUthashModules()

var txsTable {.threadvar.}: Table[string, Tx]

type
  MempoolParams* = tuple[nodeParams: NodeParams, dbInst: DbInst, id: int]

var mparams {.threadvar.}: MempoolParams
var dbInst {.threadvar.}: DbInst
var poolId {.threadvar.}: int
var network {.threadvar.}: Network
var kvAddrSpents {.threadvar.}: ptr KVHandle[MempoolAddrSpent]
var kvAddrTxouts {.threadvar.}: ptr KVHandle[MempoolAddrTxout]
var kvTxAddrs {.threadvar.}: ptr KVHandle[MempoolTxAddr]
var kvTxTxouts {.threadvar.}: ptr KVHandle[MempoolTxTxout]
var kvTxSpents {.threadvar.}: ptr KVHandle[MempoolTxSpent]
var kvUnconfs {.threadvar.}: ptr KVHandle[MempoolUnconf]

const MAX_TXS_GET_ONCE = 100

type
  KVHandles = object
    kvAddrSpentsHandle: KVHandle[MempoolAddrSpent]
    kvAddrTxoutsHandle: KVHandle[MempoolAddrTxout]
    kvTxAddrsHandle: KVHandle[MempoolTxAddr]
    kvTxTxoutsHandle: KVHandle[MempoolTxTxout]
    kvTxSpentsHandle: KVHandle[MempoolTxSpent]
    kvUnconfsHandle: KVHandle[MempoolUnconf]

  KVs* = object
    kvAddrSpents*: ptr KVHandle[MempoolAddrSpent]
    kvAddrTxouts*: ptr KVHandle[MempoolAddrTxout]
    kvTxAddrs*: ptr KVHandle[MempoolTxAddr]
    kvTxTxouts*: ptr KVHandle[MempoolTxTxout]
    kvTxSpents*: ptr KVHandle[MempoolTxSpent]
    kvUnconfs*: ptr KVHandle[MempoolUnconf]

var kvHandles: ptr UncheckedArray[KVHandles]
var kvs*: ptr UncheckedArray[KVs]
var kvsLen*: int

var kvLock: RWLock

proc init*(mempoolNumber: int) =
  kvHandles = cast[ptr UncheckedArray[KVHandles]](allocShared0(sizeof(KVHandles) * mempoolNumber))
  kvs = cast[ptr UncheckedArray[KVs]](allocShared0(sizeof(KVs) * mempoolNumber))
  zeroMem(kvHandles, sizeof(KVHandles) * mempoolNumber)
  for i in 0..<mempoolNumber:
    kvs[i].kvAddrSpents = addr kvHandles[i].kvAddrSpentsHandle
    kvs[i].kvAddrTxouts = addr kvHandles[i].kvAddrTxoutsHandle
    kvs[i].kvTxAddrs = addr kvHandles[i].kvTxAddrsHandle
    kvs[i].kvTxTxouts = addr kvHandles[i].kvTxTxoutsHandle
    kvs[i].kvTxSpents = addr kvHandles[i].kvTxSpentsHandle
    kvs[i].kvUnconfs = addr kvHandles[i].kvUnconfsHandle
  kvsLen = mempoolNumber
  ptlockInit(kvLock)

proc deinit*() =
  kvs.deallocShared()
  kvHandles.deallocShared()
  ptlockDestroy(kvLock)

proc setParams*(mempoolParams: MempoolParams) =
  txsTable = initTable[string, Tx]()
  mparams = mempoolParams
  dbInst = mparams.dbInst
  poolId = mparams.id
  network = poolId.NetworkId.getNetwork()
  kvAddrSpents = kvs[poolId].kvAddrSpents
  kvAddrTxouts = kvs[poolId].kvAddrTxouts
  kvTxAddrs = kvs[poolId].kvTxAddrs
  kvTxTxouts = kvs[poolId].kvTxTxouts
  kvTxSpents = kvs[poolId].kvTxSpents
  kvUnconfs = kvs[poolId].kvUnconfs

type
  TxAddrVal = tuple[hash160: Hash160, addressType: AddressType, value: uint64, count: uint32]

proc aggregate(txaddrvals: seq[TxAddrVal]): seq[TxAddrVal] =
  var t = initTable[seq[byte], ref TxAddrVal]()
  for a in txaddrvals:
    var key = (a.hash160, a.addressType).toBytes
    if t.hasKey(key):
      var tkey = t[key]
      tkey.value = tkey.value + a.value
      tkey.count = tkey.count + a.count
    else:
      var ra = new TxAddrVal
      ra[] = a
      t[key] = ra
  for v in t.values:
    result.add(v[])

proc mempoolTx*(poolId: int, txid: Hash, network: Network): JsonNode =
  let kvTxTxouts = kvs[poolId].kvTxTxouts
  let kvTxSpents = kvs[poolId].kvTxSpents
  var txinvals: seq[TxAddrVal]
  var txoutvals: seq[TxAddrVal]
  let txkey = txid.toBytes
  for spent in kvTxSpents.items(txkey):
    txinvals.add((spent.val.address_hash.toBytes.Hash160, spent.val.address_type, spent.val.value, 1'u32))
  for txout in kvTxTxouts.items(txkey):
    txoutvals.add((txout.val.address_hash.toBytes.Hash160, txout.val.address_type, txout.val.value, 1'u32))
  if txinvals.len > 0 or txoutvals.len > 0:
    var addrins = newJArray()
    var addrouts = newJArray()
    var fee: uint64 = 0
    for t in txinvals.aggregate:
      addrins.add(%*{"addr": network.getAddress(t.hash160, t.addressType),
                    "val": t.value.toJson, "count": t.count})
      fee = fee + t.value
    for t in txoutvals.aggregate:
      addrouts.add(%*{"addr": network.getAddress(t.hash160, t.addressType),
                    "val": t.value.toJson, "count": t.count})
      fee = fee - t.value
    result = %*{"ins": addrins, "outs": addrouts, "fee": fee.toJson}
  else:
    result = newJNull()

proc reset*() =
  withWriteLock kvLock:
    kvAddrSpents.clear()
    kvAddrTxouts.clear()
    kvTxAddrs.clear()
    kvTxTxouts.clear()
    kvTxSpents.clear()
    kvUnconfs.clear()
  txsTable.clear()

proc update*(reset: bool) =
  if reset:
    reset()

  var mpool = rpc.getRawMemPool.send()
  var mResult = mpool["result"]
  if mResult.len > 0:
    var txids: seq[string]
    var rpcCmds: RpcCommands
    for tx in mResult:
      let txid = tx.getStr
      txids.add(txid)
      rpcCmds.add(getRawTransaction.setParams(txid))
      if txids.len >= MAX_TXS_GET_ONCE:
        break
    var rpcResults = rpcCmds.send()
    if txids.len != rpcResults.len:
      raise newException(MempoolError, "rpc failed")
    var txNews: seq[tuple[txid: Hash, tx: Tx]]
    for i, txid in txids:
      if not txsTable.hasKey(txid):
        let tx = rpcResults[i]["result"].getStr.Hex.toBytes.toTx
        txsTable[txid] = tx
        txNews.add((txid.Hex.toHash, tx))
        debug "mempool[", poolId, "] txid=", txid

    var txsAddrSendTable = initTable[seq[byte], TableRef[seq[byte], uint64]]()
    var txsAddrRecvTable = initTable[seq[byte], TableRef[seq[byte], uint64]]()

    for txNew in txNews:
      var addrsRecvTable = newTable[seq[byte], uint64]()
      let (txid, tx) = txNew
      for n, txout in tx.outs:
        if txout.value == 0:
          continue
        let addrHash = txout.script.getAddressHash160
        var addrHashFixed: Hash160
        if addrHash.addressType == AddressType.Unknown:
          info "INFO: mempool unknown address chunks=", txout.script.getScriptChunks
          addrHashFixed = addrHash.hash160.toFixedHash160
        else:
          addrHashFixed = addrHash.hash160
        let mpTxTxout = newMempoolTxTxout(n.uint32, txout.value, addrHashFixed,
                                          addrHash.addressType)
        withWriteLock kvLock:
          kvTxTxouts.add(txid.toBytes, mpTxTxout)

        let mpAddrTxout = newMempoolAddrTxout(addrHash.addressType, txid, n.uint32, txout.value)
        withWriteLock kvLock:
          kvAddrTxouts.add(addrHashFixed.toBytes, mpAddrTxout)

        let addrkey = (addrHashFixed, addrHash.addressType).toBytes
        if addrsRecvTable.hasKey(addrkey):
          addrsRecvTable[addrkey] = addrsRecvTable[addrkey] + txout.value
        else:
          addrsRecvTable[addrkey] = txout.value

      txsAddrRecvTable[txid.toBytes] = addrsRecvTable

    for txNew in txNews:
      var addrsSendTable = newTable[seq[byte], uint64]()
      let (txid, tx) = txNew
      let txidBytes = txid.toBytes
      for txin in tx.ins:
        let retTx = dbInst.getTx(txin.tx)
        if retTx.err == DbStatus.Success:
          if retTx.res.skip == 1:
            info "INFO: mempool skip tx " & $txin.tx
            continue
          let retTxout = dbInst.getTxout(retTx.res.id, txin.n)
          if retTxout.err == DbStatus.Success:
            let (value, address_hash, address_type) = retTxout.res
            let address_hash_fixed = address_hash.toFixedHash160
            let mpAddrSpent = newMempoolAddrSpent(address_type.AddressType, txin.tx, txin.n, value, txid)
            let mpTxSpent = newMempoolTxSpent(txin.tx, txin.n, value, address_hash_fixed,
                                              address_type.AddressType)
            withWriteLock kvLock:
              kvAddrSpents.add(address_hash_fixed.toBytes, mpAddrSpent)
              kvTxSpents.add(txidBytes, mpTxSpent)

            let addrkey = (address_hash_fixed, address_type).toBytes
            if addrsSendTable.hasKey(addrkey):
              addrsSendTable[addrkey] = addrsSendTable[addrkey] + value
            else:
              addrsSendTable[addrkey] = value
            continue
        else:
          info "INFO: tx not found " & $txin.tx & " in " & $txid

        var findTxout = false
        var txouts: seq[tuple[key: seq[byte], val: MempoolTxTxout]]
        withReadLock kvLock:
          for txout in kvTxTxouts.items(txin.tx.toBytes):
            if txout.val.n == txin.n:
              txouts.add(txout)

        for txout in txouts:
          if txout.val.n == txin.n:
            var doubleSpending = false

            withReadLock kvLock:
              for s in kvAddrSpents.items(txout.key):
                if s.val.n == txin.n:
                  doubleSpending = true
                  break
              if doubleSpending:
                info "INFO: mempool double spending " & $txin.tx & " " & $txin.n
              else:
                info "INFO: mempool spent " & $txin.tx & " " & $txin.n

            let mpAddrSpent = newMempoolAddrSpent(txout.val.address_type, txin.tx, txin.n, txout.val.value, txid)
            let mpTxSpent = newMempoolTxSpent(txin.tx, txin.n, txout.val.value,
                                              txout.val.address_hash.toBytes.Hash160, txout.val.address_type)
            withWriteLock kvLock:
              kvAddrSpents.add(txout.key, mpAddrSpent)
              kvTxSpents.add(txidBytes, mpTxSpent)

            let addrkey = (txout.val.address_hash, txout.val.address_type).toBytes
            if addrsSendTable.hasKey(addrkey):
              addrsSendTable[addrkey] = addrsSendTable[addrkey] + txout.val.value
            else:
              addrsSendTable[addrkey] = txout.val.value

            findTxout = true
            break

        if not findTxout:
          error "ERROR: mempool txout not found " & $txin.tx & " " & $txin.n

      txsAddrSendTable[txid.toBytes] = addrsSendTable

    for txNew in txNews:
      let (txid, _) = txNew
      let txidBytes = txid.toBytes
      let addrsSendTable = txsAddrSendTable[txidBytes]
      for k, v in addrsSendTable.pairs:
        let address_hash = k[0..19].Hash160
        let address_type = k[20].AddressType
        let mpTxAddr = newMempoolTxAddr(address_hash, address_type, 0'u8, v)
        withWriteLock kvLock:
          kvTxAddrs.add(txidBytes, mpTxAddr)
          if kvUnconfs[k].isNil:
            kvUnconfs[k] = newMempoolUnconf(v, 0)
          else:
            let uc = kvUnconfs[k]
            kvUnconfs[k] = newMempoolUnconf(uc.value_out + v, uc.value_in)

      let addrsRecvTable = txsAddrRecvTable[txidBytes]
      for k, v in addrsRecvTable.pairs:
        let address_hash = k[0..19].Hash160
        let address_type = k[20].AddressType
        let mpTxAddr = newMempoolTxAddr(address_hash, address_type, 1'u8, v)
        withWriteLock kvLock:
          kvTxAddrs.add(txidBytes, mpTxAddr)
          if kvUnconfs[k].isNil:
            kvUnconfs[k] = newMempoolUnconf(0, v)
          else:
            let uc = kvUnconfs[k]
            kvUnconfs[k] = newMempoolUnconf(uc.value_out, uc.value_in + v)

    for txNew in txNews:
      let (txid, _) = txNew
      debug mempoolTx(poolId, txid, network)

proc `%`*(obj: MempoolAddrSpentObj | MempoolAddrTxoutObj |
          MempoolTxAddrObj | MempoolTxTxoutObj | MempoolTxSpentObj): JsonNode =
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

proc `%`*(o: HashArray): JsonNode = newJString($o)

proc unconfs*(poolId: int): JsonNode =
  let kvAddrSpents = kvs[poolId].kvAddrSpents
  let kvAddrTxouts = kvs[poolId].kvAddrTxouts

  var spents: seq[tuple[key: seq[byte], val: MempoolAddrSpent]]
  var txouts: seq[tuple[key: seq[byte], val: MempoolAddrTxout]]

  withReadLock kvLock:
    for addrSpent in kvAddrSpents.items:
      spents.add(addrSpent)
    for addrTxout in kvAddrTxouts.items:
      txouts.add(addrTxout)

  var j = %*{"spents": {}, "txouts": {}}
  var jspents = j["spents"]
  var jtxouts = j["txouts"]
  for spent in spents:
    var addrHash = $spent.key
    if jspents.hasKey(addrHash):
      jspents[addrHash].add(%spent.val[])
    else:
      jspents[addrHash] = %[spent.val[]]
  for txout in txouts:
    var addrHash = $txout.key
    if jtxouts.hasKey(addrHash):
      jtxouts[addrHash].add(%txout.val[])
    else:
      jtxouts[addrHash] = %[txout.val[]]
  result = j

proc unconfs*(poolId: int, addrHash: Hash160, addrType: AddressType): MempoolUnconf =
  let kvUnconfs = kvs[poolId].kvUnconfs
  let addrkey = (addrHash.toFixedHash160, addrType).toBytes
  withReadLock kvLock:
    result = kvUnconfs[addrkey]
