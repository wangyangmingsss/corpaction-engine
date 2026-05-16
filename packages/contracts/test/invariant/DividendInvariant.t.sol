// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DividendDistributor} from "../../src/executors/DividendDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DividendInvariantHandler is Test {
    DividendDistributor public distributor;
    MockERC20 public usdc;
    bytes32 public intentId;

    address[] public holders;
    uint256[] public amounts;
    bytes32[][] public proofs;
    uint256 public totalPoolAmount;

    constructor(
        DividendDistributor _distributor,
        MockERC20 _usdc,
        bytes32 _intentId,
        address[] memory _holders,
        uint256[] memory _amounts,
        bytes32[][] memory _proofs,
        uint256 _totalPoolAmount
    ) {
        distributor = _distributor;
        usdc = _usdc;
        intentId = _intentId;
        totalPoolAmount = _totalPoolAmount;

        for (uint i = 0; i < _holders.length; i++) {
            holders.push(_holders[i]);
            amounts.push(_amounts[i]);
            proofs.push(_proofs[i]);
        }
    }

    function claim(uint256 holderIndex) external {
        holderIndex = bound(holderIndex, 0, holders.length - 1);
        address holder = holders[holderIndex];

        // Skip if already claimed
        if (distributor.claimed(intentId, holder)) return;

        vm.prank(holder);
        try distributor.claimDividend(intentId, amounts[holderIndex], proofs[holderIndex]) {} catch {}
    }
}

contract DividendInvariantTest is Test {
    DividendDistributor public distributor;
    MockERC20 public usdc;
    MockERC20 public stockToken;
    DividendInvariantHandler public handler;

    address public treasury = makeAddr("treasury");
    bytes32 public intentId = keccak256("invariant-div");

    address[] holders;
    uint256[] amounts;
    uint256 totalPool;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        stockToken = new MockERC20("AAPL", "AAPL", 18);

        DividendDistributor impl = new DividendDistributor();
        bytes memory initData = abi.encodeWithSelector(
            DividendDistributor.initialize.selector, address(this), treasury
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        distributor = DividendDistributor(address(proxy));

        // Create holders
        holders.push(makeAddr("holder0"));
        holders.push(makeAddr("holder1"));
        holders.push(makeAddr("holder2"));
        amounts.push(25e6);
        amounts.push(50e6);
        amounts.push(75e6);
        totalPool = 150e6;

        usdc.mint(address(distributor), totalPool);

        // Build merkle tree (3 leaves)
        bytes32 leaf0 = keccak256(bytes.concat(keccak256(abi.encode(holders[0], amounts[0]))));
        bytes32 leaf1 = keccak256(bytes.concat(keccak256(abi.encode(holders[1], amounts[1]))));
        bytes32 leaf2 = keccak256(bytes.concat(keccak256(abi.encode(holders[2], amounts[2]))));

        // Simple 3-leaf tree: hash(hash(l0,l1), l2)
        bytes32 pair01;
        if (leaf0 <= leaf1) {
            pair01 = keccak256(abi.encodePacked(leaf0, leaf1));
        } else {
            pair01 = keccak256(abi.encodePacked(leaf1, leaf0));
        }

        bytes32 root;
        if (pair01 <= leaf2) {
            root = keccak256(abi.encodePacked(pair01, leaf2));
        } else {
            root = keccak256(abi.encodePacked(leaf2, pair01));
        }

        bytes32[][] memory proofs = new bytes32[][](3);
        proofs[0] = new bytes32[](2);
        proofs[0][0] = leaf1;
        proofs[0][1] = leaf2;
        proofs[1] = new bytes32[](2);
        proofs[1][0] = leaf0;
        proofs[1][1] = leaf2;
        proofs[2] = new bytes32[](1);
        proofs[2][0] = pair01;

        // Initialize dividend
        bytes memory actionParams = abi.encode(
            address(usdc), totalPool, uint256(0), root,
            block.number, block.timestamp + 90 days, false, uint256(0)
        );

        ICorpActionTypes.ActionIntent memory intent = ICorpActionTypes.ActionIntent({
            intentId: intentId,
            actionType: ICorpActionTypes.ActionType.DIVIDEND,
            targetToken: address(stockToken),
            ticker: "AAPL",
            isin: "US0378331005",
            recordDate: block.timestamp,
            exDate: block.timestamp,
            effectiveDate: block.timestamp,
            actionParams: actionParams,
            sourceAttestation: keccak256("test"),
            state: ICorpActionTypes.ActionState.EXECUTING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        distributor.execute(intent);

        handler = new DividendInvariantHandler(
            distributor, usdc, intentId, holders, amounts, proofs, totalPool
        );

        targetContract(address(handler));
    }

    /// @dev Invariant: pool total == claimed + unclaimed (balance remaining in contract)
    function invariant_poolTotalEqualsClaimedPlusUnclaimed() public view {
        (,uint256 totalClaimed,,) = distributor.dividends(intentId);
        uint256 contractBalance = usdc.balanceOf(address(distributor));
        uint256 treasuryBalance = usdc.balanceOf(treasury);

        // totalPool = totalClaimed + remaining in contract (ignoring treasury transfers for non-withholding)
        assertEq(totalClaimed + contractBalance + treasuryBalance, totalPool + usdc.balanceOf(treasury));
    }
}
