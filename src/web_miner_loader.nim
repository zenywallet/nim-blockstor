# Copyright (c) 2021 zenywallet

import std/jsffi

type
  DocumentObj* = distinct JsObject
  ConsoleObj* = distinct JsObject
  WindowObj* = distinct JsObject
  JsonObj* = distinct JsObject
  WebSocketObj* = ref object
  Uint8ArrayObj* = ref object
  Uint32ArrayObj* = ref object

var document* {.importc, nodecl.}: DocumentObj
var console* {.importc, nodecl.}: ConsoleObj
var window* {.importc, nodecl.}: WindowObj
var JSON* {.importc, nodecl.}: JsonObj
var WebSocket* {.importc, nodecl.}: WebSocketObj
var Uint8Array* {.importc, nodecl.}: Uint8ArrayObj
var Uint32Array* {.importc, nodecl.}: Uint32ArrayObj
var arguments* {.importc, nodecl.}: JsObject
var Math* {.importc, nodecl.}: JsObject

converter objToJs*(obj: DocumentObj | ConsoleObj | WindowObj | JsonObj |
                  WebSocketObj | Uint8ArrayObj | Uint32ArrayObj): JsObject = obj.toJs
converter jstoDocumentObj*(js: JsObject): DocumentObj = js.to(DocumentObj)
converter jstoConsoleObj*(js: JsObject): ConsoleObj = js.to(ConsoleObj)
converter jstoWindowObj*(js: JsObject): WindowObj = js.to(WindowObj)
converter jstoJsonObj*(js: JsObject): JsonObj = js.to(JsonObj)
converter jstoWebSocketObj*(js: JsObject): WebSocketObj = js.to(WebSocketObj)
converter jstoUint8ArrayObj*(js: JsObject): Uint8ArrayObj = js.to(Uint8ArrayObj)
converter jstoUint32ArrayObj*(js: JsObject): Uint32ArrayObj = js.to(Uint32ArrayObj)

proc newWebSocket*(url, protocols: cstring): WebSocketObj {.importcpp: "new WebSocket(#, #)".}
proc newUint8Array*(): Uint8ArrayObj {.importcpp: "new Uint8Array()".}
proc newUint8Array*(length: int): Uint8ArrayObj {.importcpp: "new Uint8Array(#)".}
proc newUint8Array*(obj: JsObject): Uint8ArrayObj {.importcpp: "new Uint8Array(#)".} # typedArray, buffer
proc newUint8Array*(buffer: JsObject, byteOffset: int): Uint8ArrayObj {.importcpp: "new Uint8Array(#, #)".}
proc newUint8Array*(buffer: JsObject, byteOffset: int, length: int): Uint8ArrayObj {.importcpp: "new Uint8Array(#, #, #)".}
proc newUint32Array*(): Uint32ArrayObj {.importcpp: "new Uint32Array()".}
proc newUint32Array*(length: int): Uint32ArrayObj {.importcpp: "new Uint32Array(#)".}
proc newUint32Array*(obj: JsObject): Uint32ArrayObj {.importcpp: "new Uint32Array(#)".} # typedArray, buffer
proc newUint32Array*(buffer: JsObject, byteOffset: int): Uint32ArrayObj {.importcpp: "new Uint32Array(#, #)".}
proc newUint32Array*(buffer: JsObject, byteOffset: int, length: int): Uint32ArrayObj {.importcpp: "new Uint32Array(#, #, #)".}
proc newTextEncoder*(): JsObject {.importcpp: "new TextEncoder()".}
proc newTextDecoder*(): JsObject {.importcpp: "new TextDecoder()".}
proc newNumber*(val: JsObject): JsObject {.importcpp: "new Number(#)".}
proc newDate*(): JsObject {.importcpp: "new Date()".}

proc strToUint8Array*(str: cstring): Uint8ArrayObj =
  let textenc = newTextEncoder()
  result = (textenc.encode(str)).to(Uint8ArrayObj)

proc uint8ArrayToStr*(uint8Array: Uint8ArrayObj): cstring =
  let textdec = newTextDecoder()
  result = textdec.decode(uint8Array.toJs).to(cstring)

proc call(module: JsObject, name: cstring, para1: JsObject): JsObject {.importcpp: "#[#](#)", discardable.}
proc malloc(module: JsObject, size: int): JsObject = call(module, "_malloc".cstring, size.toJs)
proc free(module: JsObject, p: JsObject) = call(module, "_free".cstring, p)

proc hex2buf(str: cstring or JsObject): Uint8ArrayObj =
  asm """
    if(`str`.length % 2) {
      throw new Error('no even number');
    }
    return new Uint8Array(`str`.match(/.{2}/g).map(function(byte) {return parseInt(byte, 16)}));
  """

proc setInterval(cb: proc(), ms: int) {.importc.}
proc setTimeout(cb: proc(), ms: int) {.importc.}
proc postMessage(data: JsObject) {.importc.}

type
  EventListenerCb = proc(evt: JsObject)
var onMessage* {.importc: "onmessage", nodecl.}: EventListenerCb

var miner = JsObject{}

var Module {.exportc.}: JsObject

template withStack*(body: untyped) =
  block stackBlock:
    var stack = Module.stackSave()
    defer:
      Module.stackRestore(stack)
    body

Module = JsObject{
  onRuntimeInitialized: proc() =
    const NumberStr = "number".cstring
    miner.init = Module.cwrap("init", jsNull, [].toJs)
    miner.setMinerData = Module.cwrap("set_miner_data", jsNull, [NumberStr, NumberStr, NumberStr])
    miner.getMinerCount = Module.cwrap("get_miner_count", NumberStr, [].toJs)
    miner.start = Module.cwrap("start", jsNull, [].toJs)
    miner.stop = Module.cwrap("stop", jsNull, [].toJs)

    miner.init()

    proc sendReady() =
      postMessage(JsObject{cmd: "ready".cstring})

    var prevTime = 0.toJs
    proc sendStatus() =
      var minerCount = miner.getMinerCount()
      var curTime = newDate().getTime() / 1000.toJs
      var diffTime = curTime - prevTime
      if (diffTime > 0.toJs).to(bool):
        minerCount = Math.round(minerCount / diffTime)
        postMessage(JsObject{cmd: "status".cstring, data: minerCount})
      prevTime = curTime
      setTimeout(sendStatus, 3000)

    var active = false
    onMessage = proc(evt: JsObject) =
      var data = newUint8Array(116)
      data.set(hex2buf(evt.data.header))
      data.set(hex2buf(evt.data.target).reverse(), 80)
      var nonce = evt.data.nonce
      var nid = evt.data.nid
      withStack:
        var pdata = Module.stackAlloc(116)
        Module.HEAPU8.set(data, pdata)
        miner.setMinerData(pdata, nonce, nid)
      if not active:
        active = true
        prevTime = newDate().getTime() / 1000.toJs
        miner.start()
        setTimeout(sendStatus, 3000)

    sendReady(),
  preRun: [].toJs,
  postRun: [].toJs,
  print: proc() =
    console.log([].toJs.slice.call(arguments).join(' ')),
  printErr: proc() =
    console.error([].toJs.slice.call(arguments).join(' ')),
  setStatus: proc(text: JsObject) =
    console.log("status: " & text.to(cstring)),
  monitorRunDependencies: proc(left: JsObject) = discard
}
