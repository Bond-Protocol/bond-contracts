# Bond Protocol Contracts
Source code for released Bond Protocol smart contracts.

Build with [foundry](https://github.com/foundry-rs/foundry): 

```shell
forge build
```

## Deployments
The Bond system is deployed multiple chains at the same addresses:

| Contract                                        | Address                                    | Ethereum                                                                             | Arbitrum                                                                           |
| ----------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------- |
| Roles Authority                                 | 0x007A0F48A4e3d74Ab4234adf9eA9EB32f87b4b14 | [Etherscan](https://etherscan.io/address/0x007A0F48A4e3d74Ab4234adf9eA9EB32f87b4b14) | [Arbiscan](https://arbiscan.io/address/0x007A0F48A4e3d74Ab4234adf9eA9EB32f87b4b14) |
| Aggregator                                      | 0x007A66A2a13415DB3613C1a4dd1C942A285902d1 | [Etherscan](https://etherscan.io/address/0x007A66A2a13415DB3613C1a4dd1C942A285902d1) | [Arbiscan](https://arbiscan.io/address/0x007A66A2a13415DB3613C1a4dd1C942A285902d1) |
| Fixed-Expiration Teller                         | 0x007FE70dc9797C4198528aE43d8195ffF82Bdc95 | [Etherscan](https://etherscan.io/address/0x007FE70dc9797C4198528aE43d8195ffF82Bdc95) | [Arbiscan](https://arbiscan.io/address/0x007FE70dc9797C4198528aE43d8195ffF82Bdc95) |
| Fixed-Expiration Auctioneer                     | 0x007FEA32545a39Ff558a1367BBbC1A22bc7ABEfD | [Etherscan](https://etherscan.io/address/0x007FEA32545a39Ff558a1367BBbC1A22bc7ABEfD) | [Arbiscan](https://arbiscan.io/address/0x007FEA32545a39Ff558a1367BBbC1A22bc7ABEfD) |
| ERC20 Bond Token Reference (clones proxy to it) | 0xD525c81912E242D0E86BC6A05e97A7c9AD747c48 | [Etherscan](https://etherscan.io/address/0xD525c81912E242D0E86BC6A05e97A7c9AD747c48) | [Arbiscan](https://arbiscan.io/address/0xD525c81912E242D0E86BC6A05e97A7c9AD747c48) |
| Fixed-Term Teller                               | 0x007F7735baF391e207E3aA380bb53c4Bd9a5Fed6 | [Etherscan](https://etherscan.io/address/0x007F7735baF391e207E3aA380bb53c4Bd9a5Fed6) | [Arbiscan](https://arbiscan.io/address/0x007F7735baF391e207E3aA380bb53c4Bd9a5Fed6) |
| Fixed-Term Auctioneer                           | 0x007F7A1cb838A872515c8ebd16bE4b14Ef43a222 | [Etherscan](https://etherscan.io/address/0x007F7A1cb838A872515c8ebd16bE4b14Ef43a222) | [Arbiscan](https://arbiscan.io/address/0x007F7A1cb838A872515c8ebd16bE4b14Ef43a222) |

#### Testnets

| Contract                                        | Address                                    | Goerli                                                                                             | Arbitrum Goerli                                                                                  |
| ----------------------------------------------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Roles Authority                                 | 0x007A0F48A4e3d74Ab4234adf9eA9EB32f87b4b14 | [Goerli Etherscan](https://goerli.etherscan.io/address/0x007A0F48A4e3d74Ab4234adf9eA9EB32f87b4b14) | [Goerli Arbiscan](https://goerli.arbiscan.io/address/0x007A0F48A4e3d74Ab4234adf9eA9EB32f87b4b14) |
| Aggregator                                      | 0x007A66A2a13415DB3613C1a4dd1C942A285902d1 | [Goerli Etherscan](https://goerli.etherscan.io/address/0x007A66A2a13415DB3613C1a4dd1C942A285902d1) | [Goerli Arbiscan](https://goerli.arbiscan.io/address/0x007A66A2a13415DB3613C1a4dd1C942A285902d1) |
| Fixed-Expiration Teller                         | 0x007FE70dc9797C4198528aE43d8195ffF82Bdc95 | [Goerli Etherscan](https://goerli.etherscan.io/address/0x007FE70dc9797C4198528aE43d8195ffF82Bdc95) | [Goerli Arbiscan](https://goerli.arbiscan.io/address/0x007FE70dc9797C4198528aE43d8195ffF82Bdc95) |
| Fixed-Expiration Auctioneer                     | 0x007FEA32545a39Ff558a1367BBbC1A22bc7ABEfD | [Goerli Etherscan](https://goerli.etherscan.io/address/0x007FEA32545a39Ff558a1367BBbC1A22bc7ABEfD) | [Goerli Arbiscan](https://goerli.arbiscan.io/address/0x007FEA32545a39Ff558a1367BBbC1A22bc7ABEfD) |
| ERC20 Bond Token Reference (clones proxy to it) | 0xD525c81912E242D0E86BC6A05e97A7c9AD747c48 | [Goerli Etherscan](https://goerli.etherscan.io/address/0xD525c81912E242D0E86BC6A05e97A7c9AD747c48) | [Goerli Arbiscan](https://goerli.arbiscan.io/address/0xD525c81912E242D0E86BC6A05e97A7c9AD747c48) |
| Fixed-Term Teller                               | 0x007F7735baF391e207E3aA380bb53c4Bd9a5Fed6 | [Goerli Etherscan](https://goerli.etherscan.io/address/0x007F7735baF391e207E3aA380bb53c4Bd9a5Fed6) | [Goerli Arbiscan](https://goerli.arbiscan.io/address/0x007F7735baF391e207E3aA380bb53c4Bd9a5Fed6) |
| Fixed-Term Auctioneer                           | 0x007F7A1cb838A872515c8ebd16bE4b14Ef43a222 | [Goerli Etherscan](https://goerli.etherscan.io/address/0x007F7A1cb838A872515c8ebd16bE4b14Ef43a222) | [Goerli Arbiscan](https://goerli.arbiscan.io/address/0x007F7A1cb838A872515c8ebd16bE4b14Ef43a222) |