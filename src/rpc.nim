# Copyright (c) 2020 zenywallet

import libcurl, strutils, json, locks
export json

type
  CoreCommand* = enum
    addMultiSigAddress = "addmultisigaddress"
    addNode = "addnode" # bitcoind v0.8.0+
    backupWallet = "backupwallet"
    createMultiSig = "createmultisig"
    createRawTransaction = "createrawtransaction" # bitcoind v0.7.0+
    decodeRawTransaction = "decoderawtransaction" # bitcoind v0.7.0+
    decodeScript = "decodescript"
    dumpPrivKey = "dumpprivkey"
    dumpWallet = "dumpwallet" # bitcoind v0.9.0+
    encryptWallet = "encryptwallet"
    estimateFee = "estimatefee" # bitcoind v0.10.0x
    estimatePriority = "estimatepriority" # bitcoind v0.10.0+
    generate = "generate" # bitcoind v0.11.0+
    getAccount = "getaccount"
    getAccountAddress = "getaccountaddress"
    getAddedNodeInfo = "getaddednodeinfo" # bitcoind v0.8.0+
    getAddressesByAccount = "getaddressesbyaccount"
    getBalance = "getbalance"
    getBestBlockHash = "getbestblockhash" # bitcoind v0.9.0+
    getBlock = "getblock"
    getBlockchainInfo = "getblockchaininfo" # bitcoind v0.9.2+
    getBlockCount = "getblockcount"
    getBlockHash = "getblockhash"
    getBlockTemplate = "getblocktemplate" # bitcoind v0.7.0+
    getChainTips = "getchaintips" # bitcoind v0.10.0+
    getConnectionCount = "getconnectioncount"
    getDifficulty = "getdifficulty"
    getGenerate = "getgenerate"
    getInfo = "getinfo"
    getMempoolInfo = "getmempoolinfo" # bitcoind v0.10+
    getMiningInfo = "getmininginfo"
    getNetTotals = "getnettotals"
    getNetworkInfo = "getnetworkinfo" # bitcoind v0.9.2+
    getNetworkHashPs = "getnetworkhashps" # bitcoind v0.9.0+
    getNewAddress = "getnewaddress"
    getPeerInfo = "getpeerinfo" # bitcoind v0.7.0+
    getRawChangeAddress = "getrawchangeaddress" # bitcoin v0.9+
    getRawMemPool = "getrawmempool" # bitcoind v0.7.0+
    getRawTransaction = "getrawtransaction" # bitcoind v0.7.0+
    getReceivedByAccount = "getreceivedbyaccount"
    getReceivedByAddress = "getreceivedbyaddress"
    getTransaction = "gettransaction"
    getTxOut = "gettxout" # bitcoind v0.7.0+
    getTxOutProof = "gettxoutproof" # bitcoind v0.11.0+
    getTxOutSetInfo = "gettxoutsetinfo" # bitcoind v0.7.0+
    getUnconfirmedBalance = "getunconfirmedbalance" # bitcoind v0.9.0+
    getWalletInfo = "getwalletinfo" # bitcoind v0.9.2+
    help = "help"
    importAddress = "importaddress" # bitcoind v0.10.0+
    importPrivKey = "importprivkey"
    importWallet = "importwallet" # bitcoind v0.9.0+
    keypoolRefill = "keypoolrefill"
    listAccounts = "listaccounts"
    listAddressGroupings = "listaddressgroupings" # bitcoind v0.7.0+
    listLockUnspent = "listlockunspent" # bitcoind v0.8.0+
    listReceivedByAccount = "listreceivedbyaccount"
    listReceivedByAddress = "listreceivedbyaddress"
    listSinceBlock = "listsinceblock"
    listTransactions = "listtransactions"
    listUnspent = "listunspent" # bitcoind v0.7.0+
    lockUnspent = "lockunspent" # bitcoind v0.8.0+
    move = "move"
    ping = "ping" # bitcoind v0.9.0+
    prioritiseTransaction = "prioritisetransaction" # bitcoind v0.10.0+
    sendFrom = "sendfrom"
    sendMany = "sendmany"
    sendRawTransaction = "sendrawtransaction" # bitcoind v0.7.0+
    sendToAddress = "sendtoaddress"
    setAccount = "setaccount"
    setGenerate = "setgenerate"
    setTxFee = "settxfee"
    signMessage = "signmessage"
    signRawTransaction = "signrawtransaction" # bitcoind v0.7.0+
    stop = "stop"
    submitBlock = "submitblock" # bitcoind v0.7.0+
    validateAddress = "validateaddress"
    verifyChain = "verifychain" # bitcoind v0.9.0+
    verifyMessage = "verifymessage"
    verifyTxOutProof = "verifytxoutproof" # bitcoind v0.11.0+
    walletLock = "walletlock"
    walletPassphrase = "walletpassphrase"
    walletPassphraseChange = "walletpassphrasechange"

type
  RpcCommand* = object
    id*: string
    data*: string
  RpcCommands* = seq[RpcCommand]

  RpcError* = object of CatchableError

type RpcConfig* = ref object
  rpcUrl*: string      # http://hostname:port/
  rpcUserPass*: string # rpcuser:rpcpassword

var defaultRpcConfig {.threadvar.}: RpcConfig
defaultRpcConfig = RpcConfig(rpcUrl: "http://127.0.0.1:9252/",
                            rpcUserPass: "rpcuser:rpcpassword")

proc setRpcConfig*(rpcConfig: RpcConfig) =
  defaultRpcConfig = rpcConfig

proc writeCallback(buffer: cstring, size: int, nitems: int, outstream: pointer): int =
  var outbuf = cast[ref string](outstream)
  outbuf[] &= buffer
  result = size * nitems

const ADD_POST_HEADER = false
when ADD_POST_HEADER:
  var headers: PSlist
  headers = slist_append(headers, "Content-Type: application/json")

proc httpPost(rpcConfig: RpcConfig, postData: string): tuple[code: Code, data: string] =
  var outbuf: ref string = new string
  let curl: Pcurl = easy_init()
  discard curl.easy_setopt(OPT_URL, rpcConfig.rpcUrl)
  discard curl.easy_setopt(OPT_POST, 1)
  discard curl.easy_setopt(OPT_USERPWD, rpcConfig.rpcUserPass)
  discard curl.easy_setopt(OPT_POSTFIELDS, postData)
  discard curl.easy_setopt(OPT_WRITEDATA, outbuf)
  discard curl.easy_setopt(OPT_WRITEFUNCTION, writeCallback)
  when ADD_POST_HEADER:
    discard curl.easy_setopt(OPT_HTTPHEADER, headers)
  let ret = curl.easy_perform()
  curl.easy_cleanup()
  (ret, outbuf[])

proc filterAlphaNumeric(s: string): string =
  var check = true
  for c in s:
    check = c.isAlphaNumeric() and check
  if check:
    result = s
  else:
    raise newException(RpcError, "invalid parameters")

proc wrapStr*(s: string): string = "\"" & filterAlphaNumeric(s) & "\""

proc wrapStr*(val: SomeInteger | BiggestInt | JsonNode): string = $val

var rpcId: uint = 0
var rpcIdLock: Lock
initLock(rpcIdLock)

proc getId(): string =
  var id: uint
  withLock rpcIdLock:
    inc(rpcId)
    id = rpcId
  result = "bs" & $id

proc setParams*(cmd: CoreCommand, args: varargs[string, wrapStr]): RpcCommand =
  var params: string
  for v in args:
    if params.len > 0:
      params.add(",")
    params.add(v)
  var id = getId()
  if params.len > 0:
    result = RpcCommand(id: id, data: "{\"id\":\"" & $id & "\",\"method\":\"" & $cmd & "\",\"params\":[" & $params & "]}")
  else:
    result = RpcCommand(id: id, data: "{\"id\":\"" & $id & "\",\"method\":\"" & $cmd & "\"}")

proc send*(cmd: CoreCommand, rpcConfig: RpcConfig, args: varargs[string, wrapStr]): JsonNode =
  let rpcCmd = setParams(cmd, args)
  let ret = httpPost(rpcConfig, rpcCmd.data)
  if ret.code == E_OK:
    if ret.data.len == 0:
      raise newException(RpcError, "no data")
    result = parseJson(ret.data)
    if not result.hasKey("id") or result["id"].getStr != rpcCmd.id:
      raise newException(RpcError, $result)
  else:
    raise newException(RpcError, $ret.code)

template send*(cmd: CoreCommand, args: varargs[string, wrapStr]): JsonNode =
  send(cmd, defaultRpcConfig, args)

proc send*(rpcCmd: RpcCommand, rpcConfig: RpcConfig = defaultRpcConfig): JsonNode =
  let ret = httpPost(rpcConfig, rpcCmd.data)
  if ret.code == E_OK:
    if ret.data.len == 0:
      raise newException(RpcError, "no data")
    result = parseJson(ret.data)
    if not result.hasKey("id") or result["id"].getStr != rpcCmd.id:
      raise newException(RpcError, $result)
  else:
    raise newException(RpcError, $ret.code)

proc send*(rpcCmds: RpcCommands, rpcConfig: RpcConfig = defaultRpcConfig): JsonNode =
  var cmds: string
  var ids: seq[string]
  for x in rpcCmds:
    if cmds.len > 0:
      cmds.add(",")
    cmds.add(x.data)
    ids.add(x.id)
  cmds = "[" & cmds & "]"
  let ret = httpPost(rpcConfig, cmds)
  if ret.code == E_OK:
    if ret.data.len == 0:
      raise newException(RpcError, "no data")
    result = parseJson(ret.data)
    if result.len == ids.len:
      var i = 0
      for r in result:
        if not r.hasKey("id") or r["id"].getStr != ids[i]:
          raise newException(RpcError, $result)
        inc(i)
    else:
      raise newException(RpcError, $result)
  else:
    raise newException(RpcError, $ret.code)


when isMainModule:
  try:
    var rpcConfig = RpcConfig(
      rpcUrl: "http://127.0.0.1:9252/",
      rpcUserPass: "rpcuser:rpcpassword")
    setRpcConfig(rpcConfig)

    let d0 = getBlockHash.send(0)
    echo d0
    echo getBlock.send(d0["result"].getStr, 0)
    let d1 = getBlockHash.setParams(1).send()
    echo d1
    echo getBlock.setParams(d1["result"].getStr, 0).send()
    echo getBlockchainInfo.send()
    echo getBlockchainInfo.setParams().send()

    var rpcCmds: RpcCommands
    rpcCmds.add(getBlockHash.setParams(0))
    rpcCmds.add(getBlockHash.setParams(1))
    rpcCmds.add(getBlockHash.setParams(2))
    echo rpcCmds.send()

    echo getBlockTemplate.send(%*{"rules": ["segwit"]})

  except:
    let e = getCurrentException()
    echo e.name, ": ", e.msg
