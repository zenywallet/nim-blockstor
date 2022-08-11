# Copyright (c) 2022 zenywallet

import jsffi
import jslib
import os

var this {.importc, nodecl.}: JsObject
var module {.importc, nodecl.}: JsObject

# https://github.com/pierrec/js-cuint
{.emit: staticRead(currentSourcePath().parentDir() / "../../deps/js-cuint/lib/uint64.js").}

var ModuleUINT64: JsObject

if not this.UINT64.isNil:
  ModuleUINT64 = this.UINT64
elif not module.exports.isNil:
  ModuleUINT64 = module.exports
else:
  raise

type
  Uint64Obj* = JsObject
  Uint64* = ref object of Uint64Obj

proc newUint64(jsMod: JsObject, val: uint): Uint64 {.importcpp: "new #(#)".}

proc newUint64*(val: uint = 0): Uint64 = ModuleUINT64.newUint64(val)

proc newUint64*(sval: cstring): Uint64 =
  result = newUint64(0)
  result.fromString(sval)

proc newUint64*(jval: JsObject): Uint64 =
  let typ = jsTypeOf(jval)
  if typ == "number":
    result = newUint64(jval.to(uint))
  elif typ == "string":
    result = newUint64(jval.to(cstring))
  else:
    raise

proc `+`*(a, b: Uint64): Uint64 =
  result = a.clone().to(Uint64)
  result.add(b)

proc `-`*(a, b: Uint64): Uint64 =
  result = a.clone().to(Uint64)
  result.subtract(b)

proc `*`*(a, b: Uint64): Uint64 =
  result = a.clone().to(Uint64)
  result.multiply(b)

proc `/`*(a, b: Uint64): Uint64 =
  result = a.clone().to(Uint64)
  result.div(b)

proc remainder*(a: Uint64): Uint64 = a.toJs.remainder.to(Uint64)

proc a00*(a: Uint64): uint16 {.importcpp: "#._a00".}
proc a16*(a: Uint64): uint16 {.importcpp: "#._a16".}
proc a32*(a: Uint64): uint16 {.importcpp: "#._a32".}
proc a48*(a: Uint64): uint16 {.importcpp: "#._a48".}

proc toUint8Array*(a: Uint64): Uint8Array =
  result = newUint8Array([
    a.a00 and 0xff'u8, a.a00 shr 8,
    a.a16 and 0xff'u8, a.a16 shr 8,
    a.a32 and 0xff'u8, a.a32 shr 8,
    a.a48 and 0xff'u8, a.a48 shr 8].toJs)

proc toNumber*(a: Uint64): int = a.toJs.toNumber().to(int)  # last 32 bits are dropped

proc toString*(a: Uint64): cstring = a.toString(10).to(cstring)


when isMainModule:
  var a = newUint64(9)
  var b = newUint64(3)
  console.log((a + b).toString)
  console.log((a - b).toString)
  console.log((a * b).toString)
  console.log((a / b).toString)

  var val = newUint64("18446744073709551615")
  console.log(val.toString, val.toUint8Array)
  val = val / newUint64(255)
  console.log(val.toString, val.toUint8Array)

  block jsobj_number:
    var x = 12345.toJs
    echo jsTypeOf(x)
    var y = newUint64(x)
    console.log(y.toString)

  block jsobj_string:
    var x = "12345".toJs
    echo jsTypeOf(x)
    var y = newUint64(x)
    console.log(y.toString)
