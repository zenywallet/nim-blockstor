# Copyright (c) 2020 zenywallet

import net, nativesockets, posix
import strutils, sequtils, algorithm
import times, os, re
import bytes, reader, utils, blocks, tx
import json, db, address, tables

when not compileOption("threads"):
  {.error: "requires --threads:on option.".}

type
  Version = distinct uint32

  MessageHeader = object
    version: Version
    command: string
    length: int
    checkSum: uint32

  MessageBody = seq[byte]

  Message = ref object
    header: MessageHeader
    body: MessageBody

  InventryType = enum
    ERROR
    MSG_TX
    MSG_BLOCK
    MSG_FILTERED_BLOCK
    MSG_CMPCT_BLOCK
    MSG_WITNESS_TX = 0x40000001
    MSG_WITNESS_BLOCK
    MSG_FILTERED_WITNESS_BLOCK

  Node* = ref object
    serverIp*: string
    port*: uint16
    protocolVersion*: uint32
    messageStart*: uint32
    networkId*: NetworkId
    network*: Network
    sin*: Sockaddr_in
    sock*: SocketHandle
    messageChannel*: ptr Channel[Message]
    recvThread*: Thread[tuple[sock: SocketHandle, recvBufLen: int, messageChannel: ptr Channel[Message]]]

  BlockParserError* = object of CatchableError


proc msgVersion(node: Node): seq[byte] =
  let now = getTime()
  (node.protocolVersion.uint32, 0xd'u64, now.toUnix.uint64, Pad(26), Pad(26),
    0xa5a5'u64, VarStr("/blockstor:0.2.0/"), 0'u32).toBytes

proc command(s: string): FixedStr {.inline.} = newFixedStr(s, 12)

proc message(node: Node, cmd: string, payload: seq[byte] = @[]): seq[byte] =
  var checksum = sha256d(payload)
  (node.messageStart.uint32.toBE, command(cmd), payload.len.uint32,
    checksum[0..<4], payload).toBytes

proc `$`*(ver: Version): string = "0x" & ver.uint32.toBytesBE.toHex

proc newNode*(params: tuple[ip: string, port: uint16, protocolVersion: uint32,
                          messageStart: uint32, networkId: NetworkId]): Node =
  var node = new Node
  node.serverIp = params.ip
  node.port = params.port
  node.protocolVersion = params.protocolVersion
  node.messageStart = params.messageStart
  node.networkId = params.networkId
  node.network = getNetwork(node.networkId)
  var address: IpAddress = parseIpAddress(node.serverIp)
  node.sin.sin_family = type(node.sin.sin_family)(Domain.AF_INET.toInt)
  copyMem(addr node.sin.sin_addr, unsafeAddr address.address_v4[0], sizeof(node.sin.sin_addr))
  node.sin.sin_port = nativesockets.ntohs(node.port)
  node.sock = createNativeSocket()
  node

proc nodeRecvThread(params: tuple[sock: SocketHandle, recvBufLen: int, messageChannel: ptr Channel[Message]]) {.thread.} =
  var recvBuf = newSeq[byte](params.recvBufLen)
  var parseData: seq[byte]

  while true:
    var recvLen = params.sock.recv(addr recvBuf[0], recvBuf.len.cint, 0.cint)
    if recvLen <= 0:
      break
    parseData = parseData & recvBuf[0..<recvLen]
    while true:
      if parseData.len < 24:
        break
      var bodyLen = parseData[16].toUint32.int
      var msgLen = 24 + bodyLen
      if parseData.len < msgLen:
        break
      var header = MessageHeader(version: Version(parseData[0].toUint32.toBE),
                                command: parseData[4..<16].toString.replace(re"\0+$", ""),
                                length: bodyLen,
                                checksum: parseData[20].toUint32)
      var body = MessageBody(parseData[24..<msgLen])
      params.messageChannel[].send(Message(header: header, body: body))
      parseData = parseData[msgLen..^1]

proc startRecvThread(node: Node) =
  const SO_RCVBUF: cint = 8
  var tcp_rmem = node.sock.getSockOptInt(SOL_SOCKET, SO_RCVBUF)
  echo "RECVBUF=", tcp_rmem
  createThread(node.recvThread, nodeRecvThread, (node.sock, tcp_rmem, node.messageChannel))

proc connect*(node: Node): bool =
  result = node.sock.connect(cast[ptr SockAddr](addr node.sin), sizeof(node.sin).SockLen) == 0
  node.messageChannel = cast[ptr Channel[Message]](allocShared0(sizeof(Channel[Message])))
  node.messageChannel[].open()
  node.startRecvThread()

proc close*(node: Node) =
  discard node.sock.shutdown(SHUT_RDWR)
  node.sock.close()
  node.recvThread.joinThread()
  node.messageChannel[].close()
  deallocShared(node.messageChannel)

proc send*(sock: SocketHandle, data: seq[byte]): bool =
  var ret = sock.send(unsafeAddr data[0], data.len.cint, 0.cint)
  if ret < 0:
    var retry = 0
    while errno == EINTR:
      ret = sock.send(unsafeAddr data[0], data.len.cint, 0.cint)
      if ret >= 0 or retry >= 100:
        break
      inc(retry)
  result = ret > 0

var seq_id = 0'u64

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

proc writeBlock(dbInst: DbInst, height: int, hash: BlockHash, blk: Block) =
  dbInst.setBlockHash(height, hash, blk.header.time, seq_id)

  var base_seq_id = seq_id
  var addrouts = newSeq[seq[AddrVal]](blk.txs.len)
  var addrins = newSeq[seq[AddrVal]](blk.txs.len)

  if blk.txs.len != blk.txn.int:
    raise newException(BlockParserError, "txn conflict")

  for idx, tx in blk.txs:
    var sid = base_seq_id + idx.uint64
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
    var sid = base_seq_id + idx.uint64

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
    var sid = base_seq_id + idx.uint64

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

  seq_id = seq_id + blk.txs.len.uint64

import rpc, terminal

proc progress(height: int, hash: BlockHash, blkTime: int64) =
  var ret_getBlockCount = rpc.getBlockCount.send()
  var blockCount = ret_getBlockCount["result"].getInt

  stdout.eraseLine
  stdout.styledWrite(styleBright, fgCyan, now().format("yyyy-MM-dd HH:mm:ss") &
                    " height=" & $height & "/" & $blockCount &
                    " delay=" & $(blockCount - height) & " " & $hash & " " &
                    blkTime.fromUnix.format("yyyy-MM-dd HH:mm:ss"))
  stdout.flushFile

proc main() =
  stdout.hideCursor
  proc quit() {.noconv.} =
    stdout.showCursor
  addQuitProc(quit)

  var node_BitZeny_mainnet = (ip: "127.0.0.1",
                              port: 9253'u16,
                              protocolVersion: 70015'u32,
                              messageStart: 0xdaa5bef9'u32,
                              networkId: NetworkId.BitZeny_mainnet)

  var node_BitZeny_testnet = (ip: "127.0.0.1",
                              port: 19253'u16,
                              protocolVersion: 70015'u32,
                              messageStart: 0x59454e59'u32,
                              networkId: NetworkId.BitZeny_testnet)

  var node = newNode(node_BitZeny_mainnet)
  var dbInst = db.open("data" / $node.networkId)
  defer:
    dbInst.close()

  if node.connect():
    defer:
      node.close()

    var height = 0
    var blockHashes: seq[BlockHash]
    var reqHashes: seq[BlockHash]
    var prevBlkHash: BlockHash
    var prevBlkTime: int64
    var prevCheckTime = getTime()

    proc checkSendErr(flag: bool) =
      if not flag:
        raise newException(BlockParserError, "send error")

    checkSendErr node.sock.send(node.message("version", node.msgVersion()))

    var check_count = 0
    while true:
      var queue = node.messageChannel[].peek()
      if queue < 500 and reqHashes.len < 500 and blockHashes.len > 0:
        var data = node.message("getblocks", (node.protocolVersion.uint32, VarInt(1),
                          blockHashes[^1], Pad(32)).toBytes)
        checkSendErr node.sock.send(data)

        var invs: seq[byte]
        var n = 0
        for h in blockHashes:
          reqHashes.add(h)
          invs &= (MSG_BLOCK.ord.uint32, h).toBytes
          inc(n)
        blockHashes = @[]
        var getdataMsg = node.message("getdata", (VarInt(n), invs).toBytes)
        checkSendErr node.sock.send(getdataMsg)

      if queue > 0:
        var message = node.messageChannel[].recv()
        case message.header.command:
        of "version":
          checkSendErr node.sock.send(node.message("verack"))

        of "verack":
          var data = node.message("getblocks", (node.protocolVersion.uint32, VarInt(1),
                                  Pad(32), Pad(32)).toBytes)
          checkSendErr node.sock.send(data)

        of "ping":
          checkSendErr node.sock.send(node.message("pong", message.body))

        of "pong":
          discard

        of "inv":
          var reader = newReader(message.body)
          var n = reader.getVarInt
          for i in 0..<n:
            var invType = reader.getUint32

            if InventryType(invType) == InventryType.MSG_BLOCK:
              var hash = BlockHash(reader.getBytes(32))
              blockHashes.add(hash)
            else:
              reader.skip(32)

        of "block":
          var b = message.body.toBlock
          if reqHashes.len > 0:
            var hash = reqHashes[0]
            reqHashes = reqHashes[1..^1]
            if (cast[seq[byte]](prevBlkHash)).len == 0:
              prevBlkHash = b.header.prev
            if cast[seq[byte]](prevBlkHash) == cast[seq[byte]](b.header.prev):
              prevBlkHash = hash
              prevBlkTime = b.header.time.int64
              inc(height)
              dbInst.writeBlock(height, hash, b)

              let time = getTime()
              let dur = time - prevCheckTime
              if dur > initDuration(seconds = 3):
                prevCheckTime = time
                progress(height, prevBlkHash, prevBlkTime)

        of "reject":
          var reader = newReader(message.body)
          var reject_message = reader.getVarStr
          var reject_code = reader.getUint8
          var reject_reason = reader.getVarStr
          stdout.eraseLine
          echo message.header.command &
                " message=" & reject_message &
                " code=" & reject_code.toHex &
                " reason=" & reject_reason

        else:
          stdout.eraseLine
          echo "ignore ", message.header.command

        check_count = 0

      else:
        sleep(100)
        if reqHashes.len == 0 and blockHashes.len == 0:
          if height > 0:
            progress(height, prevBlkHash, prevBlkTime)
          inc(check_count)
          if check_count >= 200:
            stdout.writeLine("")
            break


when isMainModule:
  main()
