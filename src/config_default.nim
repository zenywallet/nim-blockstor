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
