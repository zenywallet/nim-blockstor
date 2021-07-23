# Copyright (c) 2021 zenywallet

import address
import bytes

{.used.}

var strtmp {.threadvar.}: string
var networks {.threadvar.}: seq[Network]

proc address_init*() {.exportc.} =
  networks = @[]
  for nid in NetworkId.low..NetworkId.high:
    networks.add(getNetwork(nid.NetworkId))

proc get_address*(networkId: int, hash160: ptr UncheckedArray[byte], size: cint,
                addressType: uint8): cstring {.exportc.} =
  strtmp = getAddress(networks[networkId], hash160.toBytes(size).Hash160, addressType.AddressType) & "\0"
  result = strtmp.cstring

proc get_address_from_hex*(networkId: int, hash160_hex: cstring, addressType: uint8): cstring {.exportc.} =
  echo ($hash160_hex).Hex.toBytes.Hash160
  echo $hash160_hex
  strtmp = getAddress(networks[networkId], ($hash160_hex).Hex.toBytes.Hash160, addressType.AddressType) & "\0"
  result = strtmp.cstring

proc check_address*(address: cstring): bool {.exportc.} = checkAddress($address)

#[
void address_init();
char* get_address(int nid, char* hash160, int size, uint8_t address_type);
char* get_address_from_hex(int nid, char* hash160_hex, uint8_t address_type);
bool* check_address(char* address);
]#
