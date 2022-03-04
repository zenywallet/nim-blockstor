# Copyright (c) 2021 zenywallet

import jsffi

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


type
  Stream* = cint

const DEOXY_EXPORTS = true
when DEOXY_EXPORTS:
  asm """
  var deoxy = {};
  """
  var deoxy {.importc, nodecl.}: JsObject
else:
  var deoxy = JsObject{}

var deoxyMod: JsObject
deoxyMod = JsObject{
  onRuntimeInitialized: proc() =
    var Module = deoxyMod
    const NumberStr = "number".cstring
    deoxy.onOpen = Module.cwrap("onOpen", jsNull, [NumberStr])
    deoxy.onClose = Module.cwrap("onClose", jsNull, [NumberStr])
    deoxy.onMessage = Module.cwrap("onMessage", jsNull, [NumberStr, NumberStr, NumberStr])
    deoxy.send = Module.cwrap("send", NumberStr, [NumberStr, NumberStr, NumberStr])
    deoxy.streams = deoxy.streams or JsObject{}

    proc Module_call(module: JsObject, name: cstring, para1: JsObject): JsObject {.importcpp: "#[#](#)", discardable.}
    proc Module_malloc(size: int): JsObject = Module_call(Module, "_malloc".cstring, size.toJs)
    proc Module_free(p: JsObject) = Module_call(Module, "_free".cstring, p)

    deoxy.wsSend = proc(stream: Stream, data: Uint8ArrayObj): bool =
      var ws = deoxy.streams[stream]
      if not ws.isNil and ws.readyState == WebSocket.OPEN:
        ws.send(data)
        return true
      return false

    deoxy.cmdSend = proc(stream: Stream, data: JsObject): bool =
      var d = strToUint8Array(JSON.stringify(data).to(cstring))
      var size = d.length.to(cint)
      var p = Module_malloc(size)
      Module.HEAPU8.set(d, p)
      result = deoxy.send(stream, p, size).to(bool)
      Module_free(p)

    deoxy.close = proc(stream: Stream) =
      var ws = deoxy.streams[stream]
      if not ws.isNil:
        ws.close()
        discard jsDelete(deoxy.streams[stream])

    deoxy.connect = proc(stream: Stream, url: cstring, protocols: cstring) =
      var ws = newWebSocket(url, protocols)
      ws.binaryType = "arraybuffer".cstring

      ws.onmessage = proc(evt: JsObject) =
        var data = newUint8Array(evt.data)
        var size = data.length.to(cint)
        var p = Module_malloc(size)
        Module.HEAPU8.set(data, p)
        deoxy.onMessage(stream, p, size)
        Module_free(p)

      ws.onclose = proc() =
        deoxy.onClose(stream)
        discard jsDelete(deoxy.streams[stream])

      ws.onopen = proc(evt: JsObject) =
        deoxy.onOpen(stream)

      deoxy.streams[stream] = ws

    deoxy.error = proc(msg: cstring) =
      console.error(msg)

    deoxy.uiMain = Module.cwrap("uiMain", NumberStr, [].toJs)
    asm """
      async function launch() {
        try {
          deoxy.uiMain();
        } catch(e) {
          console.log(e);
        }
      }
      launch();
    """,
  preRun: [].toJs,
  postRun: [].toJs,
  print: proc() =
    console.log([].toJs.slice.call(arguments).join(' ')),
  printErr: proc() =
    console.error([].toJs.slice.call(arguments).join(' ')),
  canvas: (proc(): JsObject =
    var canvas = document.getElementById("canvas")
    canvas.addEventListener("webglcontextlost", proc(e: JsObject) =
      document.getElementById("overlap").innerText = "Please reload the page.".cstring
      e.preventDefault(),
      false)
    return canvas
    )(),
  setStatus: proc(text: JsObject) =
    console.log("status: " & text.to(cstring))
    document.getElementById("status").innerText = text,
  monitorRunDependencies: proc(left: JsObject) = discard
}

window.onerror = proc(evt: JsObject) =
  console.error("onerror: " & evt.message.to(cstring))

asm """
var Module = `deoxyMod`;
"""
