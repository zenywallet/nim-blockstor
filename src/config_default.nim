# blockstor config

when declared(blockstor):
  nodes = @[(ip: "127.0.0.1",
              port: 9253'u16,
              protocolVersion: 70015'u32,
              messageStart: 0xdaa5bef9'u32,
              networkId: NetworkId.BitZeny_mainnet,
              rpcUrl: "http://127.0.0.1:9252/",
              rpcUserPass: "rpcuser:rpcpassword",
              workerEnable: true),
            (ip: "127.0.0.1",
              port: 19253'u16,
              protocolVersion: 70015'u32,
              messageStart: 0x59454e59'u32,
              networkId: NetworkId.BitZeny_testnet,
              rpcUrl: "http://127.0.0.1:19252/",
              rpcUserPass: "rpcuser:rpcpassword",
              workerEnable: true)]

elif declared(server):
  const SERVER_LABELS = [
          "Bitcoin_mainnet",
          "BitZeny_testnet"]
  const RPC_WORKER_NUM = 2

elif declared(address):
  type
    NetworkId* {.pure.} = enum
      BitZeny_mainnet
      BitZeny_testnet
  const
    Networks = [
      Network(
        pubKeyPrefix: 81'u8,
        scriptPrefix: 5'u8,
        wif: 128'u8,
        bech32: "sz",
        bech32Extra: @["bz"],
        testnet: false),
      Network(
        pubKeyPrefix: 111'u8,
        scriptPrefix: 196'u8,
        wif: 239'u8,
        bech32: "tz",
        testnet: true)]

elif declared(ui):
  const WEBSOCKET_PROTOCOL = "deoxy-0.1"
  const WEBSOCKET_ENTRY_URL = "ws://localhost:8000/ws"
