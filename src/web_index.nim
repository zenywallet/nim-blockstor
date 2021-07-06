# Copyright (c) 2021 zenywallet

import templates

proc index*(): string =
  tmpli html"""
<!DOCTYPE html>
<meta charset="utf-8">
<title>blockstor - a block explorer for wallet</title>
<style>
body {
  margin: 0;
  background-color: #738c99;
}
#canvas {
  position: absolute;
  top: 0;
  left: 0;
  margin: 0;
  border: 0;
  width: 100%;
  height: 100%;
  overflow: hidden;
  display: block;
  image-rendering: optimizeSpeed;
  image-rendering: -moz-crisp-edges;
  image-rendering: -o-crisp-edges;
  image-rendering: -webkit-optimize-contrast;
  image-rendering: optimize-contrast;
  image-rendering: crisp-edges;
  image-rendering: pixelated;
}
#overlap {
  z-index: 100;
  position: absolute;
  bottom: 4px;
  left: 4px;
  color: white;
  pointer-events: none;
  font-size: 1em;
}
#status {
  z-index: 100;
  position: absolute;
  top: 4px;
  left: 4px;
  color: white;
  pointer-events: none;
  font-size: 0.8em;
}
</style>
<div id="overlap">blockstor - a block explorer for wallet</div>
<canvas id="canvas"></canvas>
<div id="status"></div>
<script async src="ui.js"></script>
"""

when isMainModule:
  echo index()
