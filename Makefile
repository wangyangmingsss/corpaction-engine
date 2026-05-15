.PHONY: build test deploy clean install

# ========== CONTRACTS ==========

install:
	cd packages/contracts && forge install

build:
	cd packages/contracts && forge build --sizes

test:
	cd packages/contracts && forge test -vvv

test-fuzz:
	cd packages/contracts && forge test --match-path 'test/fuzz/*' -vvv

test-coverage:
	cd packages/contracts && forge coverage --report lcov

gas-report:
	cd packages/contracts && forge test --gas-report

deploy-testnet:
	cd packages/contracts && forge script script/Deploy.s.sol \
		--rpc-url $(RPC_URL) --broadcast --verify

# ========== SERVICES ==========

services-build:
	cd packages/services/ingestion && npm run build
	cd packages/services/processor && npm run build
	cd packages/services/validator && npm run build

sdk-build:
	cd packages/sdk && npm run build

# ========== DOCKER ==========

docker-up:
	docker-compose up -d

docker-down:
	docker-compose down

docker-logs:
	docker-compose logs -f

docker-build:
	docker-compose build

# ========== FULL STACK ==========

all: install build test services-build sdk-build

clean:
	cd packages/contracts && forge clean
	rm -rf packages/services/ingestion/dist
	rm -rf packages/services/processor/dist
	rm -rf packages/services/validator/dist
	rm -rf packages/sdk/dist
