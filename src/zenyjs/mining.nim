# Copyright (c) 2022 zenywallet

import zenyjs
import jsffi except `.=`
import jslib
import asyncjs
import arraylib
import json
import templates
import strformat
import times
import deoxy

let ui {.compileTime, used.} = true
import os, macros
macro includeConfig: untyped =
  const configFile = currentSourcePath().parentDir() / ".." / "config.nim"
  let existTest = staticExec("test -f \"" & configFile & "\" && echo \"find\"")
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

import address
include karax / prelude


proc index*(): string {.compileTime.} =
  tmpli html"""
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Web Mining Benchmark</title>
<script src="https://cdn.jsdelivr.net/npm/jquery@3.3.1/dist/jquery.min.js"></script>
<link rel="stylesheet" type="text/css" href="https://cdn.jsdelivr.net/npm/fomantic-ui@2.8.8/dist/semantic.min.css">
<script src="https://cdn.jsdelivr.net/npm/fomantic-ui@2.8.8/dist/semantic.min.js"></script>
<style>
body {
  background-color: #414b52;
  color: #cfdae3;
}
.main.container {
  padding-top: 2em;
  padding-bottom: 6em;
}
.ui.inverted.segment {
  background-color: rgba(27, 28, 29, 0.3);
}
.ui.inverted.toggle.checkbox input:checked ~ label::before,
.ui.inverted.toggle.checkbox input:focus:checked ~ label::before {
  background-color: #08cf26 !important;
}
.ui.mining.checkbox label {
  font-size: 1.1em;
}
.ui.tag.label::after {
  visibility: hidden;
}
.ui.tag.label {
  padding-left: 0.8em;
  padding-right: 0.8em;
}
.hash {
  text-overflow: ellipsis;
  white-space: nowrap;
  max-width: 100%;
  overflow: hidden;
}
a.ui.label:hover {
  background-color: #888;
  border-color: #888;
}
.ui.inverted.label {
  background-color: #808080;
}
.ui.inverted.toggle.checkbox label:hover::before {
  background: rgba(94, 94, 94, 0.9) !important;
}
.ui.inverted.toggle.checkbox label::before {
  background-color: rgba(94, 94, 94, 0.9) !important;
}
.ui.rating {
  display: inline-block;
  white-space: normal;
}
.microchip.icon {
  color: #808080;
}
.header .blockheight {
  margin-left: 0.7em;
}
.ui.form .fields {
  -ms-flex-wrap: nowrap !important;
  flex-wrap: nowrap !important;
  margin-bottom: 1em !important;
}
.ui.form:not(.unstackable) .fields:not(.unstackable)>.field, .ui.form:not(.unstackable) .fields:not(.unstackable)>.fields {
  width: auto !important;
  margin: 0 !important;
}
</style>
</head>
<body>
<div id="mining"></div>
<script src="/mining.js"></script>
<!-- thanks, https://github.com/tholman/github-corners - change hover to triangle area only -->
<svg width="80" height="80" viewBox="0 0 250 250" style="fill:rgba(32,40,45,.8); color:#fff; position: absolute; top: 0; border: 0; right: 0;" aria-labelledby="githublink"><title id="githublink">View source on GitHub</title><a href="https://github.com/zenywallet/nim-blockstor" xlink:href="https://github.com/zenywallet/nim-blockstor" class="github-corner"><path d="M0,0 L115,115 L130,115 L142,142 L250,250 L250,0 Z"></path><path d="M128.3,109.0 C113.8,99.7 119.0,89.6 119.0,89.6 C122.0,82.7 120.5,78.6 120.5,78.6 C119.2,72.0 123.4,76.3 123.4,76.3 C127.3,80.9 125.5,87.3 125.5,87.3 C122.9,97.6 130.6,101.9 134.4,103.2" fill="currentColor" style="transform-origin: 130px 106px;" class="octo-arm"></path><path d="M115.0,115.0 C114.9,115.1 118.7,116.5 119.8,115.4 L133.7,101.6 C136.9,99.2 139.9,98.4 142.2,98.6 C133.8,88.0 127.5,74.4 143.8,58.0 C148.5,53.4 154.0,51.2 159.7,51.0 C160.3,49.4 163.2,43.6 171.4,40.1 C171.4,40.1 176.1,42.5 178.8,56.2 C183.1,58.6 187.2,61.8 190.9,65.4 C194.5,69.0 197.7,73.2 200.1,77.6 C213.8,80.2 216.3,84.9 216.3,84.9 C212.7,93.1 206.9,96.0 205.4,96.6 C205.1,102.4 203.0,107.8 198.3,112.5 C181.9,128.9 168.3,122.5 157.7,114.1 C157.9,116.9 156.7,120.9 152.7,124.9 L141.0,136.5 C139.8,137.7 141.6,141.9 141.8,141.8 Z" fill="currentColor" class="octo-body"></path></a></svg><style>.github-corner:hover .octo-arm{animation:octocat-wave 560ms ease-in-out}@keyframes octocat-wave{0%,100%{transform:rotate(0)}20%,60%{transform:rotate(-25deg)}40%,80%{transform:rotate(10deg)}}@media (max-width:500px){.github-corner:hover .octo-arm{animation:none}.github-corner .octo-arm{animation:octocat-wave 560ms ease-in-out}}a.github-corner{color:#eee}</style>
</body>
</html>
"""

macro genarateHtml() =
  writeFile("mining.html", index())

genarateHtml()


{.experimental: "dotOperators".}
macro `.=`*(obj: JsObject, field, value: untyped): untyped =
  let importString = "#." & $field & " = #"
  result = quote do:
    proc helper(o: JsObject, v: auto)
      {.importjs: `importString`, gensym.}
    helper(`obj`, `value`)


proc jq(selector: cstring): JsObject {.importcpp: "$$(#)".}
template fmtj(pattern: static string): untyped = fmt(pattern, '<', '>')


import strutils

proc convCoin(val: string): string =
  if val.len > 8:
    result = val[0..^9] & "." & val[^8..^1]
  else:
    result = (parseFloat(val) / 100000000).formatFloat(ffDecimal, 8)
  result.trimZeros()

proc convCoin(val: JsonNode): string =
  let kind = val.kind
  if kind == JsonNodeKind.JInt:
    result = convCoin($val.getBiggestInt)
  elif kind == JsonNodeKind.JString:
    result = convCoin(val.getStr)


type Notify = enum
  Success
  Error

const NotifyVal = [Success: "success".cstring, Error: "error".cstring]

proc show(notify: Notify, msg: cstring, tag: string = "", infinite: bool = false) =
  let notifyVal = NotifyVal[notify]
  jq("body").toast(JsObject{
    title: ($notify).cstring,
    message: msg,
    class: notifyVal,
    className: JsObject{
      toast: (if tag.len > 0: ("ui message " & tag).cstring else: "ui message".cstring)
    },
    displayTime: (if infinite: 0 else: 5000)
  })

proc clearNotify(tag: string = "") =
  jq((".ui.message" & (if tag.len > 0: "." & tag else: "")).cstring).toast("close")


var appInst: KaraxInstance
var noraList: seq[string]
var activeNid: int
var statusDatas: JsonNode = %*{}
var blockDatas: JsonNode = %*{}
var addressDatas: JsonNode = %*{}
var addrlogDatas: JsonNode = %*{}
var miningAddress: string = ""
var miningAddressValid = false
var miningActive = false
var cpuCount: int
var cpuMaxCount: int
var cpuMaxCountUnknown: bool = false
var optimizedId: int
var miningWorkers = [].toJs
var miningWorkersNumber = [].toJs
var miningStatus = JsObject{}
var miningData: JsObject
var miningHashRate: int
var miningHashRateWaiting: bool
var miningPendingFinds = [].toJs
var tvalMiningDataUpdater: int
var connectionError = false
var pageUnload = false
var stream: Deoxy

import std/base64
macro constMinerScriptNames(): untyped =
  var scriptNames = ["miner.js", "miner-simd128.js"]
  var bracket = nnkBracket.newTree()
  for name in scriptNames:
    var srcBin = encode(staticRead(currentSourcePath().parentDir() / "../../public" / name))
    bracket.add(newLit("data:application/javascript;base64," & srcBin))
  newConstStmt(newIdentNode("minerScriptNames"), bracket)

constMinerScriptNames()

try:
  cpuMaxCount = window.navigator.hardwareConcurrency.to(int)
  if cpuMaxCount.toJs == jsNull:
    raise
except:
  cpuCount = 4
  cpuMaxCount = 16
  cpuMaxCountUnknown = true

cpuCount = cpuMaxCount
let cpuMaxCountStr = $cpuCount

proc changeMiningWorker(num: int) =
  miningWorkersNumber.push(num)
  var req: JsObject
  while 0 < miningWorkersNumber.length.to(int):
    req = miningWorkersNumber.shift()
  if not req.isNil:
    while req.to(int) < miningWorkers.length.to(int):
      let worker = miningWorkers.pop()
      let id = worker.id.to(cstring)
      discard jsDelete(miningStatus[id])
      worker.terminate()
    while req.to(int) > miningWorkers.length.to(int):
      let worker = newWorker(cstring(minerScriptNames[optimizedId]))
      worker.onerror = proc(e: JsObject) = console.dir(e)
      worker.id = miningWorkers.length
      worker.readyFlag = false
      worker.started = false
      worker.onmessage = bindMethod proc(this: JsObject, e: JsObject) =
        if e.data["cmd"].to(cstring) == "find".cstring:
          let findData = strToUint8Array(JSON.stringify(e.data))
          let retSend = stream.send(findData)
          if not retSend:
            miningPendingFinds.push(findData)
        elif e.data["cmd"].to(cstring) == "status".cstring:
          miningStatus[this.id.to(cstring)] = e.data["data"]
        elif e.data["cmd"].to(cstring) == "ready".cstring:
          this.readyFlag = true
      miningWorkers.push(worker)

proc postMiningData() =
  var nonce = Math.floor(Math.random() * 0x100000000.toJs)
  let step = Math.round(0x100000000.toJs / miningWorkers.length)
  for worker in items(miningWorkers):
    miningData.nonce = nonce
    worker.postMessage(miningData)
    worker.started = true
    nonce += step

proc startMiningDataUpdater() =
  var allReady = true
  for worker in items(miningWorkers):
    if not worker.readyFlag.to(bool):
      allReady = false
      break
  if allReady:
    var allStarted = true
    for worker in items(miningWorkers):
      if not worker.started.to(bool):
        allStarted = false
    if not allStarted:
      if not miningData.isNil:
        postMiningData()

  var total = 0.toJs
  for val in items(miningStatus):
    total += val
  let totalSec = Math.round(total).to(int)
  if miningHashRate != totalSec:
    miningHashRate = totalSec
    miningHashRateWaiting = false
    appInst.redraw()

  tvalMiningDataUpdater = setTimeout(startMiningDataUpdater, 1000)

proc stopMiningDataUpdater() =
  clearTimeout(tvalMiningDataUpdater)
  miningHashRate = 0
  miningHashRateWaiting = false
  appInst.redraw()

proc onRate(value: int) =
  cpuCount = value
  miningAddressValid = checkAddress(activeNid, miningAddress.cstring)
  if miningActive and miningAddressValid:
    changeMiningWorker(cpuCount)
  appInst.redraw()

proc onOptimizeChange() =
  optimizedId = jq("input:radio[name='optimize']:checked").val().to(cstring).parseInt
  changeMiningWorker(0)
  miningAddressValid = checkAddress(activeNid, miningAddress.cstring)
  if miningActive and miningAddressValid:
    changeMiningWorker(cpuCount)

proc afterScript(data: RouterData) =
  jq("#mining .mining.checkbox").checkbox()
  jq("#mining .optimize .checkbox").checkbox(JsObject{onChange: onOptimizeChange})
  jq("#mining .rating").rating(JsObject{onRate: onRate})

proc cmdSend(cmd: string) = stream.send(strToUint8Array(cmd.cstring))

proc appMain(data: RouterData): VNode =
  result = buildHtml(tdiv(class="ui inverted main text container")):
    let activeNidStr = $activeNid
    h1(class="ui inverted dividing header"): text "Web Mining Benchmark"
    if activeNid < noraList.len:
      tdiv(class="ui inverted basic buttons"):
        for i, n in noraList:
          tdiv(class=cstring("ui inverted button" & (if i == activeNid: " active" else: "")), data-value=cstring($i)):
            proc onclick(ev: Event, n: Vnode) =
              let newActiveNid = n.getAttr("data-value").parseInt
              if activeNid != newActiveNid:
                if miningActive:
                  jq(".preventnetwork.modal").modal("show")
                else:
                  let oldActiveNid = activeNid
                  activeNid = newActiveNid
                  if miningAddressValid:
                    cmdSend fmtj"""{"cmd":"addr-off","data":{"nid":<oldActiveNid>,"addr":"<miningAddress>"}}"""
                  miningAddressValid = checkAddress(activeNid, miningAddress.cstring)
                  if miningAddressValid:
                    cmdSend fmtj"""{"cmd":"addr-on","data":{"nid":<activeNid>,"addr":"<miningAddress>"}}"""
            text n
      h2(class="ui inverted dividing header"): text noraList[activeNid]
      if blockDatas.hasKey(activeNidStr):
        tdiv(class="ui inverted segment"):
          tdiv(class="ui inverted relaxed divided list"):
            for d in blockDatas[activeNidStr]["blocks"]:
              tdiv(class="item"):
                tdiv(class="content"):
                  let blkTime = d["time"].getInt.fromUnix()
                  tdiv(class="header"):
                    text blkTime.format("yyyy-MM-dd HH:mm:ss (zzz)")
                    span(class="blockheight"):
                      text "#" & $d["height"].getInt
                  code: tdiv(class="hash"): text d["hash"].getStr
              break

      tdiv(class="ui inverted center aligned segment"):
        if miningHashRateWaiting:
          span(class="ui inverted huge text"): verbatim "&nbsp;"
          tdiv(class="ui active"):
            tdiv(class="ui active slow inverted double loader")
        else:
          span(class="ui inverted huge text"): text $miningHashRate
          text " H/s"

      tdiv(class="ui inverted fluid right labeled left icon input"):
        italic(class="piggy bank icon")
        input(type="text", placeholder="Enter your receiving address", value=miningAddress.cstring, disabled=miningActive.toDisabled()):
          proc onkeyup(ev: Event, n: Vnode) =
            let oldMiningAddress = miningAddress
            miningAddress = $n.value()
            if oldMiningAddress != miningAddress:
              if miningAddressValid:
                cmdSend fmtj"""{"cmd":"addr-off","data":{"nid":<activeNid>,"addr":"<oldMiningAddress>"}}"""
              miningAddressValid = checkAddress(activeNid, miningAddress.cstring)
              if miningAddressValid:
                cmdSend fmtj"""{"cmd":"addr-on","data":{"nid":<activeNid>,"addr":"<miningAddress>"}}"""
        a(class="ui inverted tag label"):
          proc onclick(ev: Event, n: Vnode) =
            if miningActive:
              miningActive = false
              if miningAddressValid:
                cmdSend fmtj"""{"cmd":"mining-off","data":{"nid":<activeNid>,"addr":"<miningAddress>"}}"""
                miningData = jsNull
                changeMiningWorker(0)
                stopMiningDataUpdater()
              jq(".ui.mining.checkbox").checkbox("set unchecked")
            else:
              miningActive = true
              jq(".ui.mining.checkbox").checkbox("set checked")
              miningAddressValid = checkAddress(activeNid, miningAddress.cstring)
              if miningAddressValid:
                clearNotify()
                miningHashRateWaiting = true
                changeMiningWorker(cpuCount)
                startMiningDataUpdater()
                cmdSend fmtj"""{"cmd":"mining-on","data":{"nid":<activeNid>,"addr":"<miningAddress>"}}"""
              else:
                Notify.Error.show("invalid address")

                setTimeout(proc() =
                  jq(".ui.mining.checkbox").checkbox("set unchecked")
                  miningActive = false
                  changeMiningWorker(0)
                  stopMiningDataUpdater()
                  appInst.redraw(), 1000)

          tdiv(class="ui inverted right aligned toggle mining checkbox"):
            input(type="checkbox")
            label: text "Mining"

      let cpuCountStr = $cpuCount
      h3(class="ui inverted header"):
        italic(class="microchip icon")
        tdiv(class="content"):
          text fmt"CPU {cpuCountStr} / {cpuMaxCountStr}"
          if cpuMaxCountUnknown:
            text " (Unknown CPU)"

      tdiv(class="ui orange huge rating", data-icon="circle", data-rating=cpuCountStr.cstring, data-max-rating=cpuMaxCountStr.cstring):
        for i in 0..<cpuCount:
          italic(class="circle icon active")
        for i in 0..<cpuMaxCount - cpuCount:
          italic(class="circle icon")

      tdiv(class="ui inverted optimize form"):
        tdiv(class="inline fields"):
          label: text "Optimization"
          tdiv(class="field"):
            tdiv(class="ui radio checkbox"):
              input(type="radio", name="optimize", value="0", checked="checked")
              label: text "None"
          tdiv(class="field"):
            tdiv(class="ui radio checkbox"):
              input(type="radio", name="optimize", value="1")
              label: text "SIMD128"

      h3(class="ui inverted header"): text "Your Receiving Address"
      tdiv:
        bold: text "address: "
        if miningAddress.len > 0:
          text miningAddress
          if not miningAddressValid:
            text " "
            tdiv(class="ui red label"): text "invalid"
        else:
          text "(unset)"

      if addressDatas.hasKey(activeNidStr) and miningAddress == addressDatas[activeNidStr]["addr"].getStr:
        tdiv:
          bold: text "amount: "
          if addressDatas[activeNidStr].hasKey("val"):
            text convCoin(addressDatas[activeNidStr]["val"])
          else:
            text "(unused)"
        tdiv:
          if addressDatas[activeNidStr].hasKey("utxo_count"):
            bold: text "utxo count: "
            text $addressDatas[activeNidStr]["utxo_count"].getInt

      h3(class="ui inverted header"): text "Transaction Logs"
      if addrlogDatas.hasKey(activeNidStr) and
        miningAddress == addrlogDatas[activeNidStr]["addr"].getStr and
        addrlogDatas[activeNidStr]["addrlogs"].len > 0:
        tdiv(class="ui inverted segment"):
          tdiv(class="ui inverted relaxed divided list"):
            for d in addrlogDatas[activeNidStr]["addrlogs"]:
              tdiv(class="item"):
                tdiv(class="content"):
                  let blkTime = d["blktime"].getInt.fromUnix()
                  tdiv(class="header"):
                    text blkTime.format("yyyy-MM-dd HH:mm:ss (zzz)")
                    span(class="blockheight"): text "#" & $d["height"].getInt
                  code:
                    tdiv(class="hash"): text "txid: " & d["tx"].getStr
                    tdiv: text "value: " & convCoin(d["val"])
                    tdiv:
                      text "type: " & (if d["trans"].getInt == 0: "Send" else: "Receive")
                      if d["mined"].getInt == 1:
                        text " (mined)"
      else:
        tdiv: text "no logs"

    else:
      if connectionError:
        tdiv: text "Server connection failed."
      else:
        tdiv(class="ui active dimmer"):
          tdiv(class="ui indeterminate text loader"): text "Loading ..."


let miningPreventChangeNetwork = buildHtml(tdiv(class="ui preventnetwork inverted modal")):
  tdiv(class="header"): text "Network changes are preventing"
  tdiv(class="content"): p: text "Mining is currently running. Please stop the mining before changing the network."
  tdiv(class="actions"):
    tdiv(class="ui inverted ok button"): text "OK"

document.body.appendChild(vnodeToDom(miningPreventChangeNetwork))

appInst = setInitializer(appMain, "mining", afterScript)
appInst.surpressRedraws = false
appInst.redraw()

window.addEventListener("beforeunload", proc() = pageUnload = true)

zenyjs.ready:
  proc onRecv(data: Uint8Array) =
    let d = parseJson($data.uint8ArrayToStr())
    let recvType = d["type"].getStr
    let recvData = d["data"]

    if recvType == "mining":
      while 0 < miningPendingFinds.length.to(int):
        let findData = miningPendingFinds.shift().to(Uint8Array)
        let retSend = stream.send(findData)
        if not retSend:
          miningPendingFinds.push(findData)
          break
      miningData = JSON.parse(cstring($recvData))
      postMiningData()

    elif recvType == "noralist":
      noraList = @[]
      for n in recvData:
        noraList.add(n.getStr)
      appInst.redraw()

    elif recvType == "status":
      let nid = recvData["nid"].getInt
      let nidStr = $nid
      statusDatas[nidStr] = recvData

      let height = recvData["height"].getInt
      let lastHeight = recvData["lastHeight"].getInt
      if height == lastHeight:
        cmdSend fmtj"""{"cmd":"block","data":{"nid":<nid>,"height":<height>,"limit":1}}"""

    elif recvType == "block":
      let nid = recvData["nid"].getInt
      let nidStr = $nid
      blockDatas[nidStr] = recvData
      if activeNid == nid:
        appInst.redraw()

    elif recvType == "addr":
      let nid = recvData["nid"].getInt
      let nidStr = $nid
      addressDatas[nidStr] = recvData
      appInst.redraw()
      cmdSend fmtj"""{"cmd":"addrlog","data":{"nid":<nid>,"addr":"<miningAddress>","rev":1}}"""

    elif recvType == "addrlog":
      let nid = recvData["nid"].getInt
      let nidStr = $nid
      addrlogDatas[nidStr] = recvData
      appInst.redraw()

  proc onReady() =
    cmdSend """{"cmd":"status-on"}"""
    cmdSend """{"cmd":"noralist"}"""
    if miningActive:
      cmdSend fmtj"""{"cmd":"addr-on","data":{"nid":<activeNid>,"addr":"<miningAddress>"}}"""
      cmdSend fmtj"""{"cmd":"mining-on","data":{"nid":<activeNid>,"addr":"<miningAddress>"}}"""

  proc onOpen() =
    connectionError = false
    clearNotify("connect")

  proc onClose() =
    if not pageUnload:
      if not connectionError:
        Notify.Error.show("Server connection failed.", "connect", true)
        when defined(MINING_STOP_WHEN_DISCONNECTED):
          setTimeout(proc() =
            jq(".ui.mining.checkbox").checkbox("set unchecked")
            miningActive = false
            changeMiningWorker(0)
            stopMiningDataUpdater()
            appInst.redraw(), 1000)
      connectionError = true
      appInst.redraw()

  stream.connect(WEBSOCKET_ENTRY_URL, WEBSOCKET_PROTOCOL, onOpen, onReady, onRecv, onClose)
