# Aragon OSx CRISP (Interfold) voting plugin 🚀

Welcome to CRISP voting plugin for Aragon OSx!

This plugin is designed to enable secure and private voting on Aragon OSx enabled DAOs.

Under the hood, the plugin uses CRISP on Interfold to enable voting privately on a DAO's proposals. 

Read more about CRISP and Interfold [here](https://interfold.com) and [here](https://docs.interfold.com/introduction).

## Configuration

- DEPLOYMENT_PRIVATE_KEY: private key of the address deploying the plugin
- RPC_URL: RPC URL of the target network
- CHAIN_ID: Chain ID of the target network
- NETWORK_NAME: Name of the target network
- VERIFIER: Source code verifier to use (e.g., etherscan)
- DAO_FACTORY_ADDRESS: Address of the DAO Factory on the target network
- PLUGIN_REPO_FACTORY_ADDRESS: Address of the Plugin Repo Factory on the target network
- TOKEN_NAME: Name of the voting token
- TOKEN_SYMBOL: Symbol of the voting token
- MINT_SETTINGS_RECEIVERS: Comma-separated list of addresses to receive initial token minting
- MINT_SETTINGS_AMOUNT: Amount of tokens to mint to each receiver (in wei)
- INTERFOLD_ADDRESS: Address of the Interfold contract
- CRISP_PROGRAM_ADDRESS: Address of the CRISP program contract
- MINIMUM_PARTICIPATION: Minimum participation required for a vote to be valid
- MINIMUM_DURATION: Minimum duration of a vote (in seconds)
- MINIMUM_PROPOSER_VOTING_POWER: Minimum voting power required to propose a vote
- THRESHOLD_0: First threshold for Interfold ciphernode committee (e.g. 1 out of 2 nodes required)
- THRESHOLD_1: Second threshold for Interfold ciphernode committee (e.g. 2 out of 2 nodes required)
- CRISP_PROGRAM_PARAMS: Encoded parameters for the CRISP program 
- COMPUTE_PROVIDER_PARAMS: Encoded parameters for the compute provider

## Deployment

To deploy the plugin, first configure the `.env` file with the correct values. Then, run the deployment script:

```sh
forge script script/DeploySimple.s.sol:CrispVotingScript --rpc-url <rpc-url> --broadcast --verify
```

## Test

Test with a local fork of Interfold

1. Clone Interfold
2. Setup the project
   - `pnpm install && pnpm build`
3. Setup CRISP
   - `cd examples/CRISP`
   - `pnpm dev:up`
4. Run the tests
   - `pnpm test`
