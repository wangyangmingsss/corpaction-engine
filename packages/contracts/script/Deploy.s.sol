// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ActionRegistry} from "../src/core/ActionRegistry.sol";
import {ValidatorManager} from "../src/core/ValidatorManager.sol";
import {TimelockController} from "../src/core/TimelockController.sol";
import {AttestationRegistry} from "../src/verification/AttestationRegistry.sol";
import {FeeCollector} from "../src/fees/FeeCollector.sol";
import {DividendDistributor} from "../src/executors/DividendDistributor.sol";
import {SplitExecutor} from "../src/executors/SplitExecutor.sol";
import {MergerHandler} from "../src/executors/MergerHandler.sol";
import {SpinoffExecutor} from "../src/executors/SpinoffExecutor.sol";
import {DelistingManager} from "../src/executors/DelistingManager.sol";
import {TickerMigrator} from "../src/executors/TickerMigrator.sol";
import {ICorpActionTypes} from "../src/interfaces/ICorpActionTypes.sol";
import {ChainlinkPriceAdapter} from "../src/integrations/ChainlinkPriceAdapter.sol";
import {CrossChainNotifier} from "../src/integrations/CrossChainNotifier.sol";
import {CrossChainReceiver} from "../src/integrations/CrossChainReceiver.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envOr("TREASURY", deployer);
        address usdc = vm.envOr("USDC_ADDRESS", address(0));
        address lzEndpoint = vm.envOr("LZ_ENDPOINT", deployer); // LayerZero endpoint; defaults to deployer as placeholder

        console2.log("Deployer:", deployer);
        console2.log("Treasury:", treasury);

        vm.startBroadcast(deployerKey);

        // 1. Deploy ValidatorManager
        ValidatorManager validatorImpl = new ValidatorManager();
        address[] memory initialValidators = new address[](1);
        initialValidators[0] = deployer;
        bytes memory vmInit = abi.encodeWithSelector(
            ValidatorManager.initialize.selector,
            initialValidators,
            1 // superMajority (1 for testing)
        );
        ERC1967Proxy vmProxy = new ERC1967Proxy(address(validatorImpl), vmInit);
        ValidatorManager validatorManager = ValidatorManager(address(vmProxy));
        console2.log("ValidatorManager:", address(validatorManager));

        // 2. Deploy TimelockController
        TimelockController timelockImpl = new TimelockController();
        bytes memory tlInit = abi.encodeWithSelector(TimelockController.initialize.selector);
        ERC1967Proxy tlProxy = new ERC1967Proxy(address(timelockImpl), tlInit);
        console2.log("TimelockController:", address(tlProxy));

        // 3. Deploy AttestationRegistry
        AttestationRegistry attImpl = new AttestationRegistry();
        bytes memory attInit = abi.encodeWithSelector(AttestationRegistry.initialize.selector);
        ERC1967Proxy attProxy = new ERC1967Proxy(address(attImpl), attInit);
        console2.log("AttestationRegistry:", address(attProxy));

        // 4. Deploy ActionRegistry
        ActionRegistry regImpl = new ActionRegistry();
        bytes memory regInit = abi.encodeWithSelector(
            ActionRegistry.initialize.selector,
            address(validatorManager),
            7 days // intentTTL
        );
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        ActionRegistry registry = ActionRegistry(address(regProxy));
        console2.log("ActionRegistry:", address(registry));

        // Connect AttestationRegistry to ActionRegistry
        AttestationRegistry attestationRegistry = AttestationRegistry(address(attProxy));
        registry.setAttestationRegistry(address(attestationRegistry));

        // Connect TimelockController to ActionRegistry
        registry.setTimelockController(address(tlProxy));

        // 5. Deploy FeeCollector
        if (usdc != address(0)) {
            FeeCollector feeImpl = new FeeCollector();
            bytes memory feeInit = abi.encodeWithSelector(
                FeeCollector.initialize.selector, usdc, treasury
            );
            ERC1967Proxy feeProxy = new ERC1967Proxy(address(feeImpl), feeInit);
            FeeCollector feeCollector = FeeCollector(address(feeProxy));
            console2.log("FeeCollector:", address(feeCollector));
            registry.setFeeCollector(address(feeCollector));
        }

        // 6. Deploy DividendDistributor
        DividendDistributor divImpl = new DividendDistributor();
        bytes memory divInit = abi.encodeWithSelector(
            DividendDistributor.initialize.selector,
            address(registry), treasury
        );
        ERC1967Proxy divProxy = new ERC1967Proxy(address(divImpl), divInit);
        console2.log("DividendDistributor:", address(divProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.DIVIDEND, address(divProxy));

        // 7. Deploy SplitExecutor
        SplitExecutor splitImpl = new SplitExecutor();
        bytes memory splitInit = abi.encodeWithSelector(
            SplitExecutor.initialize.selector, address(registry)
        );
        ERC1967Proxy splitProxy = new ERC1967Proxy(address(splitImpl), splitInit);
        console2.log("SplitExecutor:", address(splitProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.FORWARD_SPLIT, address(splitProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.REVERSE_SPLIT, address(splitProxy));

        // 8. Deploy MergerHandler
        MergerHandler mergerImpl = new MergerHandler();
        bytes memory mergerInit = abi.encodeWithSelector(
            MergerHandler.initialize.selector, address(registry)
        );
        ERC1967Proxy mergerProxy = new ERC1967Proxy(address(mergerImpl), mergerInit);
        console2.log("MergerHandler:", address(mergerProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.MERGER_CASH, address(mergerProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.MERGER_STOCK, address(mergerProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.MERGER_HYBRID, address(mergerProxy));

        // 9. Deploy SpinoffExecutor
        SpinoffExecutor spinoffImpl = new SpinoffExecutor();
        bytes memory spinoffInit = abi.encodeWithSelector(
            SpinoffExecutor.initialize.selector, address(registry)
        );
        ERC1967Proxy spinoffProxy = new ERC1967Proxy(address(spinoffImpl), spinoffInit);
        console2.log("SpinoffExecutor:", address(spinoffProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.SPINOFF, address(spinoffProxy));

        // 10. Deploy ChainlinkPriceAdapter (non-proxy, Ownable)
        ChainlinkPriceAdapter priceAdapter = new ChainlinkPriceAdapter(deployer);
        console2.log("ChainlinkPriceAdapter:", address(priceAdapter));

        // 11. Deploy DelistingManager (with ChainlinkPriceAdapter integration)
        DelistingManager delistImpl = new DelistingManager();
        bytes memory delistInit = abi.encodeWithSelector(
            DelistingManager.initialize.selector, address(registry), address(priceAdapter)
        );
        ERC1967Proxy delistProxy = new ERC1967Proxy(address(delistImpl), delistInit);
        console2.log("DelistingManager:", address(delistProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.DELISTING, address(delistProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.LIQUIDATION, address(delistProxy));

        // 12. Deploy TickerMigrator
        TickerMigrator tickerImpl = new TickerMigrator();
        bytes memory tickerInit = abi.encodeWithSelector(
            TickerMigrator.initialize.selector, address(registry)
        );
        ERC1967Proxy tickerProxy = new ERC1967Proxy(address(tickerImpl), tickerInit);
        console2.log("TickerMigrator:", address(tickerProxy));
        registry.registerExecutor(ICorpActionTypes.ActionType.TICKER_CHANGE, address(tickerProxy));

        // 13. Deploy CrossChainNotifier (non-proxy, Ownable)
        CrossChainNotifier notifier = new CrossChainNotifier(lzEndpoint, deployer);
        console2.log("CrossChainNotifier:", address(notifier));

        // 14. Deploy CrossChainReceiver (non-proxy, Ownable)
        CrossChainReceiver receiver = new CrossChainReceiver(lzEndpoint, deployer);
        console2.log("CrossChainReceiver:", address(receiver));

        // Timelocks are managed by TimelockController (connected above).
        // The internal _timelocks mapping in ActionRegistry serves as a fallback
        // if TimelockController is not set.

        vm.stopBroadcast();

        console2.log("\n=== Deployment Complete ===");
    }
}
