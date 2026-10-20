-include .env
export

.PHONY: help deploy verify
.DEFAULT_GOAL := help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

deploy: ## Deploy the hook to mainnet
	forge script script/DeployHook.s.sol --rpc-url $(MAINNET_RPC_URL) --chain-id 1 --broadcast

verify: ## Deploy and verify the hook on Etherscan
	forge script script/DeployHook.s.sol \
	  --rpc-url $(MAINNET_RPC_URL) \
	  --broadcast \
	  --verify

coverage: ## Generates lcov.info at the project root
	forge coverage --report lcov --report-file lcov.info
