# Copyright (c) 2020 zenywallet

import os, times, tables, terminal
import bytes, tcp, rpc, db
import address, blocks, tx
import mempool
import posix
import server
import monitor
import utils

type
  WorkerParams = tuple[nodeParams: NodeParams, dbInst: DbInst, id: int]
  WrapperParams = tuple[threadFunc: proc(params: WorkerParams) {.thread.}, params: WorkerParams]
  WrapperMultiParams = tuple[threadFunc: proc(params: seq[WorkerParams]) {.thread.}, params: seq[WorkerParams]]

  BlockstorError* = object of CatchableError

var node_BitZeny_mainnet = (ip: "127.0.0.1",
                            port: 9253'u16,
                            protocolVersion: 70015'u32,
                            messageStart: 0xdaa5bef9'u32,
                            networkId: NetworkId.BitZeny_mainnet,
                            rpcUrl: "http://127.0.0.1:9252/",
                            rpcUserPass: "rpcuser:rpcpassword",
                            workerEnable: true)

var node_BitZeny_testnet = (ip: "127.0.0.1",
                            port: 19253'u16,
                            protocolVersion: 70015'u32,
                            messageStart: 0x59454e59'u32,
                            networkId: NetworkId.BitZeny_testnet,
                            rpcUrl: "http://127.0.0.1:19252/",
                            rpcUserPass: "rpcuser:rpcpassword",
                            workerEnable: true)


var nodes: seq[NodeParams]
nodes.add(node_BitZeny_mainnet)
nodes.add(node_BitZeny_testnet)

var dbnames: seq[string]
for node in nodes:
  dbnames.add($node.networkId)

echo "db open"
var dbInsts = db.opens("data", dbnames)
echo "db open - done"

var workers: seq[WorkerParams]
for i, node in nodes:
  workers.add((node, dbInsts[i], i))

var networks: seq[Network]
for node in nodes:
  networks.add(node.networkId.getNetwork)

var abort = false

type
  AddrVal = tuple[hash160: Hash160, addressType: uint8, value: uint64, utxo_count: uint32]
  AddrValRollback = tuple[hash160: Hash160, value: uint64, utxo_count: uint32]

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

proc aggregate(addrvals: seq[AddrValRollback]): seq[AddrValRollback] =
  var t = initTable[seq[byte], AddrValRollback]()
  for a in addrvals:
    var key = a.hash160.toBytes
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
    var addrvals: seq[AddrVal]
    var dustCount = 0
    for n, o in tx.outs:
      if o.value <= 546: # dust is less than 546, 546 is not
        if dustCount >= 2:
          break
        inc(dustCount)
    if dustCount >= 2:
      dbInst.setTx(txid, height, sid, 1.uint8)
    else:
      dbInst.setTx(txid, height, sid)
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

      if n == 0xffffffff'u32:
        dbInst.setMinedId(seq_id + idx.uint64, height)
      else:
        var ret_tx = dbInst.getTx(in_txid)
        if ret_tx.err == DbStatus.NotFound:
          raise newException(BlockParserError, "id not found " & $in_txid)
        if ret_tx.res.skip == 1:
          echo "skip tx " & $in_txid
          continue

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

proc writeBlockStream(dbInst: DbInst, height: int, hash: BlockHash, blk: Block, seq_id: uint64) =
  dbInst.setBlockHash(height, hash, blk.header.time, seq_id)

  var addrouts = newSeq[seq[AddrVal]](blk.txs.len)
  var addrins = newSeq[seq[AddrVal]](blk.txs.len)
  var streamAddrs = initTable[seq[byte], tuple[value: uint64, utxo_count: uint32]]()

  if blk.txs.len != blk.txn.int:
    raise newException(BlockParserError, "txn conflict")

  for idx, tx in blk.txs:
    var sid = seq_id + idx.uint64
    var txid = Hash(tx.txidBin)
    dbInst.setId(sid, txid)
    var addrvals: seq[AddrVal]
    var dustCount = 0
    for n, o in tx.outs:
      if o.value <= 546: # dust is less than 546, 546 is not
        if dustCount >= 2:
          break
        inc(dustCount)
    if dustCount >= 2:
      dbInst.setTx(txid, height, sid, 1.uint8)
    else:
      dbInst.setTx(txid, height, sid)
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

      if n == 0xffffffff'u32:
        dbInst.setMinedId(seq_id + idx.uint64, height)
      else:
        var ret_tx = dbInst.getTx(in_txid)
        if ret_tx.err == DbStatus.NotFound:
          raise newException(BlockParserError, "id not found " & $in_txid)
        if ret_tx.res.skip == 1:
          echo "skip tx " & $in_txid
          continue

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
        if addressType != AddressType.Unknown.uint8:
          streamAddrs[(hash160, addressType).toBytes] = (value, utxo_count)
      else:
        let val = ret_addrval.res.value + value
        let cnt = ret_addrval.res.utxo_count + utxo_count
        dbInst.setAddrval(hash160, val, cnt)
        if addressType != AddressType.Unknown.uint8:
          streamAddrs[(hash160, addressType).toBytes] = (val, cnt)
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
        let val = ret_addrval.res.value - value
        let cnt = ret_addrval.res.utxo_count - utxo_count
        dbInst.setAddrval(hash160, val, cnt)
        if addressType != AddressType.Unknown.uint8:
          streamAddrs[(hash160, addressType).toBytes] = (val, cnt)
      dbInst.setAddrlog(hash160, sid, 0, value, addressType)

  for k, v in streamAddrs.pairs:
    let jsonData =  %*{"val": v.value.toJson, "utxo_count": v.utxo_count}
    streamSend(k, jsonData)
    echo "streamSend tag=", k, " ", jsonData

proc rollbackBlock(dbInst: DbInst, height: int, hash: BlockHash, blk: Block, seq_id: uint64): tuple[height: int, seq_id: uint64] =
  var addrins = newSeq[seq[AddrValRollback]](blk.txs.len)
  var addrouts = newSeq[seq[AddrValRollback]](blk.txs.len)

  var prev_seq_id = seq_id - blk.txs.len.uint64
  for idx, tx in blk.txs:
    var addrvals: seq[AddrValRollback]
    for i in tx.ins:
      var in_txid = i.tx
      var n = i.n

      if n == 0xffffffff'u32:
        dbInst.delMinedId(seq_id + idx.uint64)
      else:
        var ret_tx = dbInst.getTx(in_txid)
        if ret_tx.err == DbStatus.NotFound:
          raise newException(BlockParserError, "id not found " & $in_txid)
        if ret_tx.res.skip == 1:
          echo "skip tx " & $in_txid
          continue

        var id = ret_tx.res.id
        var ret_txout = dbInst.getTxout(id, n)
        if ret_txout.err == DbStatus.NotFound:
          raise newException(BlockParserError, "txout not found " & $id)

        dbInst.setUnspent(ret_txout.res.address_hash, id, n, ret_txout.res.value)
        addrvals.add((ret_txout.res.address_hash, ret_txout.res.value, 1'u32))

    addrins[idx] = addrvals.aggregate

  for idx, tx in blk.txs:
    var sid = prev_seq_id + idx.uint64
    var txid = Hash(tx.txidBin)

    var addrvals: seq[AddrValRollback]
    for n, o in tx.outs:
      if o.value == 0:
        continue
      var addrHash = getAddressHash160(o.script)
      dbInst.delUnspent(addrHash.hash160, sid, n.uint32)
      dbInst.delTxout(sid, n.uint32)
      addrvals.add((addrHash.hash160, o.value, 1'u32))

    addrouts[idx] = addrvals.aggregate

    dbInst.delTx(txid)
    dbInst.delId(sid)

  for idx, tx in blk.txs:
    var sid = prev_seq_id + idx.uint64

    var addrvals = addrins[idx]
    for addrval in addrvals:
      var hash160 = addrval.hash160
      var value = addrval.value
      var utxo_count = addrval.utxo_count
      var ret_addrval = dbInst.getAddrval(hash160)
      if ret_addrval.err == DbStatus.NotFound:
        raise newException(BlockParserError, "address not found " & $hash160)

      dbInst.delAddrlog(hash160, sid, 0)
      dbInst.setAddrval(hash160, ret_addrval.res.value + value, ret_addrval.res.utxo_count + utxo_count)

  for idx, tx in blk.txs:
    var sid = prev_seq_id + idx.uint64

    var addrvals = addrouts[idx]
    for addrval in addrvals:
      var hash160 = addrval.hash160
      var value = addrval.value
      var utxo_count = addrval.utxo_count
      dbInst.delAddrlog(hash160, sid, 1)

      var addrLogExist = false
      for addrlog in dbInst.getAddrlogs(hash160):
        addrLogExist = true
        break

      if addrLogExist:
        var ret_addrval = dbInst.getAddrval(hash160)
        if ret_addrval.err == DbStatus.NotFound:
          raise newException(BlockParserError, "address not found " & $hash160)

        dbInst.setAddrval(hash160, ret_addrval.res.value - value, ret_addrval.res.utxo_count - utxo_count)
      else:
        dbInst.delAddrval(hash160)

  dbInst.delBlockHash(height)
  result = (height - 1, prev_seq_id)

type
  LastBlockChekcerParam* = object
    lastHeight*: int
    abort*: bool

var lastBlockChekcerParam*: ptr UncheckedArray[LastBlockChekcerParam]
template updateLastHeight(id: int) {.dirty.} =
  var retBlockCount = rpc.getBlockCount.send()
  if retBlockCount["result"].kind != JInt:
    raise newException(BlockstorError, "get block count")
  lastBlockChekcerParam[id].lastHeight = retBlockCount["result"].getInt

proc doAbort() =
  abort = true
  tcp.stop()

proc threadWrapper(wrapperParams: WrapperParams | WrapperMultiParams) {.thread.} =
  try:
    wrapperParams.threadFunc(wrapperParams.params)
  except:
    let e = getCurrentException()
    echo e.name, ": ", e.msg
    doAbort()

const MONITOR_CONSOLE = false
var monitorEnable = true
proc monitorMain(workers: seq[WorkerParams]) {.thread.} =
  when MONITOR_CONSOLE:
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
  else:
    var prev = newSeq[MonitorInfo](workers.len)
    while monitorEnable:
      for i, params in workers:
        if not params.nodeParams.workerEnable:
          continue
        var m = addr monitorInfos[][i]
        if not lastBlockChekcerParam[i].abort:
          m.lastHeight = lastBlockChekcerParam[i].lastHeight
        if m.lastHeight < m.height:
          m.lastHeight = m.height
        if prev[i].height == m.height and prev[i].hash == m.hash and
          prev[i].blkTime == m.blkTime and prev[i].lastHeight == m.lastHeight:
          continue

        if streamActive:
          let jsonData = %*{"type": "status", "data":
                          {"network": $params.nodeParams.networkId,
                          "height": m.height, "hash": $m.hash,
                          "blkTime": m.blkTime,
                          "lastHeight": m.lastHeight}}
          streamSend("status", jsonData)
          prev[i] = m[]
      sleep(400)

proc lastBlockChecker(params: WorkerParams) {.thread.} =
  rpc.setRpcConfig(RpcConfig(rpcUrl: params.nodeParams.rpcUrl, rpcUserPass: params.nodeParams.rpcUserPass))
  var cnt = 0
  while not abort and not lastBlockChekcerParam[params.id].abort:
    sleep(200)
    inc(cnt)
    if cnt < 25:
      continue
    cnt = 0
    updateLastHeight(params.id)

proc nodeWorker(params: WorkerParams) {.thread.} =
  var node = newNode(params.nodeParams)
  var dbInst = params.dbInst
  var height = 0.int
  var nextSeqId = 0'u64
  var blkHash = BlockHash(pad(32))

  rpc.setRpcConfig(RpcConfig(rpcUrl: params.nodeParams.rpcUrl, rpcUserPass: params.nodeParams.rpcUserPass))

  var retLastBlock = dbInst.getLastBlockHash()
  if retLastBlock.err == DbStatus.NotFound:
    # genesis block
    var retGenesisHash = rpc.getBlockHash.send(0)
    if retGenesisHash["result"].kind != JString:
      raise newException(BlockstorError, "genesis block hash not found")
    let genesisHash = retGenesisHash["result"].getStr.Hex.toBlockHash
    var retGenesisBlock = rpc.getBlock.send($genesisHash, 0)
    if retGenesisBlock["result"].kind != JString:
      raise newException(BlockstorError, "genesis block not found")
    let genesisBlk = retGenesisBlock["result"].getStr.Hex.toBytes.toBlock
    dbInst.writeBlock(0, genesisHash, genesisBlk, 0)
    nextSeqId = genesisBlk.txs.len.uint64
    blkHash = genesisHash
    setMonitorInfo(params.id, height, blkHash, genesisBlk.header.time.int64, height)
  else:
    # rewrite block
    var retBlock = rpc.getBlock.send($retLastBlock.res.hash, 0)
    if retBlock["result"].kind != JString:
      raise newException(BlockstorError, "last block not found")

    let blk = retBlock["result"].getStr.Hex.toBytes.toBlock
    height = retLastBlock.res.height
    nextSeqId = retLastBlock.res.start_id + blk.txs.len.uint64
    blkHash = retLastBlock.res.hash
    dbInst.writeBlock(height, blkHash, blk, nextSeqId)
    setMonitorInfo(params.id, height, blkHash, blk.header.time.int64, height)

  # block check
  template block_check() {.dirty.} =
    while height > 0:
      var retRpcHash = rpc.getBlockHash.send(height)
      if retRpcHash["result"].kind != JString:
        raise newException(BlockstorError, "rpc block not found height=" & $height)
      var retDbHash = dbInst.getBlockHash(height)
      if retDbHash.err != DbStatus.Success:
        raise newException(BlockstorError, "db block not found height=" & $height)

      var blkRpcHash = retRpcHash["result"].getStr.Hex.toBlockHash
      var blkDbHash = retDbHash.res.hash
      if blkRpcHash.toBytes == blkDbHash.toBytes:
        blkHash = blkDbHash
        break

      # rollback
      var retBlock = rpc.getBlock.send($blkDbHash, 0)
      if retBlock["result"].kind != JString:
        raise newException(BlockstorError, "rollback block not found hash=" & $blkDbHash)

      let blk = retBlock["result"].getStr.Hex.toBytes.toBlock
      let retRollback = dbInst.rollbackBlock(height, blkDbHash, blk, nextSeqId)
      height = retRollback.height
      nextSeqId = retRollback.seq_id
      echo "rollback ", height

  block_check()

  block tcpMode:
    if not node.connect():
      raise newException(BlockstorError, "connect failed: " & $node.networkId)
    echo "connect: ", node.networkId

    defer:
      node.close()

    updateLastHeight(params.id)
    var lastBlockCheckerThread: Thread[WrapperParams]
    createThread(lastBlockCheckerThread, threadWrapper, (lastBlockChecker, params))

    proc cb(tcpHeight: int, hash: BlockHash, blk: Block): bool =
      dbInst.writeBlock(tcpHeight, hash, blk, nextSeqId)
      height = tcpHeight
      nextSeqId = nextSeqId + blk.txs.len.uint64
      setMonitorInfo(params.id, height, hash, blk.header.time.int64)
      result = not abort

    node.start(params.nodeParams, height, blkHash, cb)

    lastBlockChekcerParam[params.id].abort = true
    lastBlockCheckerThread.joinThread()
    if abort:
      return

  block rpcMode:
    echo "rpc mode"
    mempool.setParams(params)

    while not abort:
      block_check()

      var blockNew = false
      var retHash = rpc.getBlockHash.send(height + 1)
      while retHash["result"].kind == JString:
        var blkRpcHash = retHash["result"].getStr.Hex.toBlockHash
        var retBlock = rpc.getBlock.send($blkRpcHash, 0)
        if retBlock["result"].kind != JString:
          raise newException(BlockstorError, "rpc block not found hash=" & $blkRpcHash)

        let blk = retBlock["result"].getStr.Hex.toBytes.toBlock
        inc(height)
        dbInst.writeBlockStream(height, blkRpcHash, blk, nextSeqId)
        nextSeqId = nextSeqId + blk.txs.len.uint64
        setMonitorInfo(params.id, height, blkRpcHash, blk.header.time.int64, height)
        if abort:
          return

        retHash = rpc.getBlockHash.send(height + 1)
        blockNew = true

      mempool.update(blockNew)

      sleep(1000)

var monitorThread: Thread[WrapperMultiParams]

proc startWorker() =
  lastBlockChekcerParam = cast[ptr UncheckedArray[LastBlockChekcerParam]](allocShared0(sizeof(LastBlockChekcerParam) * workers.len))
  monitorInfos = cast[ptr UncheckedArray[MonitorInfo]](allocShared0(sizeof(MonitorInfo) * workers.len))
  monitorInfosCount = workers.len
  createThread(monitorThread, threadWrapper, (monitorMain, workers))
  var threads = newSeq[Thread[WrapperParams]](workers.len)

  for i, params in workers:
    if params.nodeParams.workerEnable:
      createThread(threads[i], threadWrapper, (nodeWorker, params))
  threads.joinThreads()
  monitorEnable = false
  monitorThread.joinThread()
  deallocShared(lastBlockChekcerParam)
  server.stop()
  deallocShared(monitorInfos)
  dbInsts.close()
  echo "db closed"
  resetAttributes()


when MONITOR_CONSOLE:
  stdout.eraseScreen

server.setDbInsts(dbInsts, networks)
server.start()

onSignal(SIGINT, SIGTERM):
  echo "bye from signal ", sig
  doAbort()

signal(SIGPIPE, SIG_IGN)

mempool.init(nodes.len)
startWorker()
