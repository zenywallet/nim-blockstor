# Copyright (c) 2022 zenywallet

when defined(js):
  import macros, os
  const srcDir = currentSourcePath().parentDir()
  const zenyjsFilePath = srcDir / "zenyjs.js"
  macro loadZenyJS(): untyped =
    var zenyjsScript = readFile(zenyjsFilePath)
    result = nnkStmtList.newTree(
      nnkAsmStmt.newTree(
        newEmptyNode(),
        newLit(zenyjsScript)
      )
    )
  loadZenyJS()

  import jsffi
  import asyncjs
  import jslib

  type
    ModuleStatus = enum
      None
      Loading
      Ready

  var Module: JsObject
  var module_ready = ModuleStatus.None
  var wait_cb = [].toJs

  proc ZenyJS_Module(mods: JsObject): Future[JsObject] {.async, importc: "ZenyJS".}

  proc purge_wait_cb(module: JsObject) =
    var p = wait_cb.shift().to(proc(module: JsObject))
    while not p.isNil:
      p(module)
      p = wait_cb.shift().to(proc(module: JsObject))

  proc loadModule(cb: proc(module: JsObject)) {.async, discardable.} =
    wait_cb.push(cb)
    if module_ready == ModuleStatus.None:
      module_ready = ModuleStatus.Loading
      Module = JsObject{
        onRuntimeInitialized: proc() =
          Module.malloc = proc(size: int): JsObject =
            Module.modCall("_malloc".cstring, size.toJs)
          Module.free = proc(p: JsObject) =
            Module.modCall("_free".cstring, p)
          module_ready = ModuleStatus.Ready,
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

      discard await ZenyJS_Module(Module)
      purge_wait_cb(Module)
    else:
      proc wait_ready() =
        if module_ready == ModuleStatus.Ready:
          purge_wait_cb(Module)
        else:
          setTimeout(wait_ready, 100)
      wait_ready()

  template ready*(body: untyped) =
    loadModule(proc(module: JsObject) =
      when declared(arraylib):
        arraylib.init(module)
      when declared(bip32):
        bip32.init(module)
      when declared(deoxy):
        deoxy.init(module)
      when declared(tx):
        tx.init(module)
      when declared(address.Network):
        address.init(module)
      when declared(base58):
        base58.init(module)
      discard (proc() {.async.} = body)()
    )

elif defined(emscripten):
  import arraylib
  import bip32
  import deoxy
  import tx
  import address
  import base58

  const ZENYJS_MODULE_NAME = "ZenyJS"
  {.passL: "-s EXPORT_NAME=" & ZENYJS_MODULE_NAME.}

  const DEFAULT_EXPORTED_FUNCTIONS = ["_malloc", "_free"]
  const DEFAULT_EXPORTED_RUNTIME_METHODS = ["ccall", "cwrap", "UTF8ToString"]

  import macros
  macro collectExportedFunctions*(): untyped =
    result = nnkStmtList.newTree()
    var bracket = nnkBracket.newTree()
    for functionName in DEFAULT_EXPORTED_FUNCTIONS:
      bracket.add(newLit(functionName))
    when declared(arraylib.EXPORTED_FUNCTIONS):
      for functionName in arraylib.EXPORTED_FUNCTIONS:
        bracket.add(newLit(functionName))
    when declared(bip32.EXPORTED_FUNCTIONS):
      for functionName in bip32.EXPORTED_FUNCTIONS:
        bracket.add(newLit(functionName))
    when declared(deoxy.EXPORTED_FUNCTIONS):
      for functionName in deoxy.EXPORTED_FUNCTIONS:
        bracket.add(newLit(functionName))
    when declared(tx.EXPORTED_FUNCTIONS):
      for functionName in tx.EXPORTED_FUNCTIONS:
        bracket.add(newLit(functionName))
    when declared(address.EXPORTED_FUNCTIONS):
      for functionName in address.EXPORTED_FUNCTIONS:
        bracket.add(newLit(functionName))
    when declared(base58.EXPORTED_FUNCTIONS):
      for functionName in base58.EXPORTED_FUNCTIONS:
        bracket.add(newLit(functionName))
    result.add(
      nnkConstSection.newTree(
        nnkConstDef.newTree(
          newIdentNode("exportedFunctions"),
          newEmptyNode(),
          bracket
        )
      )
    )

  collectExportedFunctions()

  {.passL: "-s EXPORTED_FUNCTIONS='" & $exportedFunctions & "'".}
  {.passL: "-s EXPORTED_RUNTIME_METHODS='" & $DEFAULT_EXPORTED_RUNTIME_METHODS & "'".}
