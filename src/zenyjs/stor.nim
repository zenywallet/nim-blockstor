# Copyright (c) 2022 zenywallet

proc set*(tag, data: cstring) {.importc: "localStorage.setItem".}

proc get*(tag: cstring): cstring {.importc: "localStorage.getItem".}

proc del*(tag: cstring) {.importc: "localStorage.removeItem".}

proc clear*() {.importc: "localStorage.clear".}


when isMainModule:
  stor.set("testtag", "testdata")
  var d = stor.get("testtag")
  if not d.isNil:
    echo d
  stor.del("testtag")
  stor.clear()
