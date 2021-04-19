# Copyright (c) 2020 zenywallet

import os, times, tables, terminal
import bytes, tcp, rpc, db
import address, blocks, tx
import std/exitprocs
import algorithm

type
  WorkerParams = tuple[nodeParams: NodeParams, dbInst: DbInst, id: int]

  BlockstorError* = object of CatchableError

var node_BitZeny_mainnet = (ip: "127.0.0.1",
                            port: 9253'u16,
                            protocolVersion: 70015'u32,
                            messageStart: 0xdaa5bef9'u32,
                            networkId: NetworkId.BitZeny_mainnet,
                            rpcUrl: "http://127.0.0.1:9252/",
                            rpcUserPass: "rpcuser:rpcpassword")

var node_BitZeny_testnet = (ip: "127.0.0.1",
                            port: 19253'u16,
                            protocolVersion: 70015'u32,
                            messageStart: 0x59454e59'u32,
                            networkId: NetworkId.BitZeny_testnet,
                            rpcUrl: "http://127.0.0.1:19252/",
                            rpcUserPass: "rpcuser:rpcpassword")


var nodes: seq[NodeParams]
nodes.add(node_BitZeny_mainnet)
nodes.add(node_BitZeny_testnet)

var dbnames: seq[string]
for node in nodes:
  dbnames.add($node.networkId)

var dbInsts = db.opens("data", dbnames)

var workers: seq[WorkerParams]
for i, node in nodes:
  workers.add((node, dbInsts[i], i))

proc quit() {.noconv.} =
  resetAttributes()
  if dbInsts.len > 0:
    dbInsts[0].close()

exitprocs.addExitProc(quit)

type
  AddrVal = tuple[hash160: Hash160, addressType: uint8, value: uint64, utxo_count: uint32]

proc aggregate(addrvals: seq[AddrVal]): seq[AddrVal] =
  var t = initTable[seq[byte], AddrVal]()
  for a in addrvals:
    var key = (a.hash160, a.addressType).toBytes
    if t.hasKey(key):
      t[key].value = t[key].value + a.value
      t[key].utxo_count = t[key].utxo_count + a.utxo_count
    else:
      t[key] = a
  for v in t.values:
    result.add(v)

proc writeBlock(dbInst: DbInst, height: int, hash: BlockHash, blk: Block, seq_id: uint64) =
  dbInst.setBlockHash(height, hash, blk.header.time, seq_id)

  var addrouts = newSeq[seq[AddrVal]](blk.txs.len)
  var addrins = newSeq[seq[AddrVal]](blk.txs.len)

  if blk.txs.len != blk.txn.int:
    raise newException(BlockParserError, "txn conflict")

  for idx, tx in blk.txs:
    var sid = seq_id + idx.uint64
    var txid = Hash(tx.txidBin)
    dbInst.setId(sid, txid)
    dbInst.setTx(txid, height, sid)
    var addrvals: seq[AddrVal]
    for n, o in tx.outs:
      var addrHash = getAddressHash160(o.script)
      dbInst.setTxout(sid, n.uint32, o.value, addrHash.hash160, uint8(addrHash.addressType))
      dbInst.setUnspent(addrHash.hash160, sid, n.uint32, o.value)
      addrvals.add((addrHash.hash160, uint8(addrHash.addressType), o.value, 1'u32))

    addrouts[idx] = addrvals.aggregate

  for idx, tx in blk.txs:
    var addrvals: seq[AddrVal]
    for i in tx.ins:
      var in_txid = i.tx
      var n = i.n

      if n != 0xffffffff'u32:
        var ret_tx = dbInst.getTx(in_txid)
        if ret_tx.err == DbStatus.NotFound:
          raise newException(BlockParserError, "id not found " & $in_txid)

        var id = ret_tx.res.id
        var ret_txout = dbInst.getTxout(id, n)
        if ret_txout.err == DbStatus.NotFound:
          raise newException(BlockParserError, "txout not found " & $id)

        dbInst.delUnspent(ret_txout.res.address_hash, id, n)
        addrvals.add((ret_txout.res.address_hash, ret_txout.res.address_type, ret_txout.res.value, 1'u32))

    addrins[idx] = addrvals.aggregate

  for idx, tx in blk.txs:
    var sid = seq_id + idx.uint64

    var addrvals = addrouts[idx]
    for addrval in addrvals:
      var hash160 = addrval.hash160
      var addressType = uint8(addrval.addressType)
      var value = addrval.value
      var utxo_count = addrval.utxo_count
      var ret_addrval = dbInst.getAddrval(hash160)
      if ret_addrval.err == DbStatus.NotFound:
        dbInst.setAddrval(hash160, value, utxo_count)
      else:
        dbInst.setAddrval(hash160, ret_addrval.res.value + value, ret_addrval.res.utxo_count + utxo_count)
      dbInst.setAddrlog(hash160, sid, 1, value, addressType)

  for idx, tx in blk.txs:
    var sid = seq_id + idx.uint64

    var addrvals = addrins[idx]
    for addrval in addrvals:
      var hash160 = addrval.hash160
      var addressType = uint8(addrval.addressType)
      var value = addrval.value
      var utxo_count = addrval.utxo_count
      var ret_addrval = dbInst.getAddrval(hash160)
      if ret_addrval.err == DbStatus.NotFound:
        raise newException(BlockParserError, "address not found " & $hash160)
      else:
        dbInst.setAddrval(hash160, ret_addrval.res.value - value, ret_addrval.res.utxo_count - utxo_count)
      dbInst.setAddrlog(hash160, sid, 0, value, addressType)

type
  ArrayBlockHash = array[32, byte]

  MonitorInfo = object
    height: int
    hash: ArrayBlockHash
    blkTime: int64

proc `$`*(data: ArrayBlockHash): string =
  var b = data
  algorithm.reverse(b)
  bytes.toHex(b)

var monitorInfos = cast[ptr UncheckedArray[MonitorInfo]](allocShared0(sizeof(MonitorInfo) * workers.len))

var monitorEnable = true
proc monitor(workers: seq[WorkerParams]) {.thread.} =
  while monitorEnable:
    stdout.setCursorPos(0, 0)
    stdout.eraseLine
    stdout.styledWriteLine(styleBright, fgCyan, now().format("yyyy-MM-dd HH:mm:ss"))
    for i, params in workers:
      var m = monitorInfos[][i]
      stdout.eraseLine
      if m.height > 0:
        stdout.styledWriteLine(styleBright, fgCyan, $params.nodeParams.networkId &
                              " #" & $m.height & " " & $m.hash &
                              " " & m.blkTime.fromUnix.format("yyyy-MM-dd HH:mm:ss"))
      else:
        stdout.styledWriteLine(styleBright, fgCyan, $params.nodeParams.networkId)
    stdout.setCursorPos(0, terminalHeight() - 1)
    stdout.flushFile
    sleep(1000)

proc setMonitorInfo(workerId: int, height: int, hash: BlockHash, time: int64) =
  var info = addr monitorInfos[][workerId]
  info.height = height
  if cast[seq[byte]](hash).len == 32:
    copyMem(addr info.hash[0], unsafeAddr cast[ptr seq[byte]](unsafeAddr hash)[][0], sizeof(info.hash))
  info.blkTime = time

proc nodeWorker(params: WorkerParams) {.thread.} =
  var node = newNode(params.nodeParams)
  var dbInst = params.dbInst

  block tcpMode:
    if not node.connect():
      raise newException(BlockstorError, "connect failed: " & $node.networkId)
    echo "connect: ", node.networkId

    defer:
      node.close()

    var seq_id = 0'u64

    proc cb(height: int, hash: BlockHash, blk: Block) =
      dbInst.writeBlock(height, hash, blk, seq_id)
      seq_id = seq_id + blk.txs.len.uint64
      setMonitorInfo(params.id, height, hash, blk.header.time.int64)

    node.start(params.nodeParams, 0, BlockHash(pad(32)), cb)

proc startWorker() =
  var monitorThread: Thread[seq[WorkerParams]]
  createThread(monitorThread, monitor, workers)
  var threads = newSeq[Thread[WorkerParams]](workers.len)

  for i, params in workers:
    createThread(threads[i], nodeWorker, params)
  threads.joinThreads()
  monitorEnable = false
  monitorThread.joinThread()
  deallocShared(monitorInfos)


when isMainModule:
  stdout.eraseScreen
  startWorker()
