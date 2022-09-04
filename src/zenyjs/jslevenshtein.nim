# Copyright (c) 2022 zenywallet

import jsffi
import os

var module {.importc, nodecl.}: JsObject

# https://github.com/gustf/js-levenshtein
{.emit: staticRead(currentSourcePath().parentDir() / "../../deps/js-levenshtein/index.js").}

var Module = JsObject{levenshtein: module.exports}

proc levenshtein*(a, b: cstring): int = Module.levenshtein(a, b).to(int)


when isMainModule:
  echo levenshtein("kitten", "sitting")
