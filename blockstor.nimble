# Package

version       = "0.2.0"
author        = "zenywallet"
description   = "Block Explorer API for Wallet Service"
license       = "MIT"
srcDir        = "src"
bin           = @["blockstor"]



# Dependencies

requires "nim >= 1.2.0"
requires "nimcrypto"
requires "libcurl"
requires "zip"
