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
  # server
  when ENABLE_SSL:
    const HTTP_PORT = 80
    const HTTPS_PORT = 443
    const HTTP_HOST_NAME = "localhost"
    const HTTPS_HOST_NAME = "localhost"
    const REDIRECT_URL = "https://" & HTTPS_HOST_NAME
    const DEBUG_LOG = false

    const CERT_PATH = "."
    const CERT_SITES = @["localhost"]
    const CERT_FILE = "cert.pem"
    const PRIVKEY_FILE = "privkey.pem"
    const CHAIN_FILE = "fullchain.pem"
    const SSL_AUTO_RELOAD = true
  else:
    const HTTP_PORT = 8080
    const HTTPS_PORT = 8000
    const HTTP_HOST_NAME = "localhost:8080"
    const HTTPS_HOST_NAME = "localhost:8000"
    const REDIRECT_URL = "http://" & HTTPS_HOST_NAME
    const DEBUG_LOG = true

  # stream
  const SERVER_LABELS = [
          "BitZeny_mainnet",
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
