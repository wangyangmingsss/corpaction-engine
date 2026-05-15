// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ValidatorManager} from "../../src/core/ValidatorManager.sol";
import {ICorpActionTypes} from "../../src/interfaces/ICorpActionTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ValidatorManagerTest is Test {
    ValidatorManager public mgr;

    address public admin = address(this);
    uint256 public val1Key;
    address public val1;
    uint256 public val2Key;
    address public val2;
    uint256 public val3Key;
    address public val3;
    address public nonAdmin = makeAddr("nonAdmin");

    function setUp() public {
        (val1, val1Key) = makeAddrAndKey("validator1");
        (val2, val2Key) = makeAddrAndKey("validator2");
        (val3, val3Key) = makeAddrAndKey("validator3");

        address[] memory initial = new address[](3);
        initial[0] = val1;
        initial[1] = val2;
        initial[2] = val3;

        ValidatorManager impl = new ValidatorManager();
        bytes memory initData = abi.encodeWithSelector(
            ValidatorManager.initialize.selector, initial, 3
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        mgr = ValidatorManager(address(proxy));
    }

    function test_addValidator() public {
        address val4 = makeAddr("validator4");
        mgr.addValidator(val4);

        assertTrue(mgr.isValidator(val4));
        assertEq(mgr.getValidatorCount(), 4);
    }

    function test_removeValidator() public {
        mgr.removeValidator(val3);

        assertFalse(mgr.isValidator(val3));
        assertEq(mgr.getValidatorCount(), 2);
    }

    function test_revert_addDuplicateValidator() public {
        vm.expectRevert(abi.encodeWithSelector(
            ValidatorManager.AlreadyValidator.selector, val1
        ));
        mgr.addValidator(val1);
    }

    function test_revert_removeNonValidator() public {
        address nobody = makeAddr("nobody");
        vm.expectRevert(abi.encodeWithSelector(
            ValidatorManager.NotValidator.selector, nobody
        ));
        mgr.removeValidator(nobody);
    }

    function test_quorumConfiguration() public {
        mgr.setQuorum(ICorpActionTypes.ActionType.DIVIDEND, 2);
        assertEq(mgr.getQuorum(ICorpActionTypes.ActionType.DIVIDEND), 2);

        mgr.setQuorum(ICorpActionTypes.ActionType.MERGER_CASH, 3);
        assertEq(mgr.getQuorum(ICorpActionTypes.ActionType.MERGER_CASH), 3);
    }

    function test_signatureRecovery() public {
        bytes32 msgHash = keccak256("test message");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(val1Key,
            keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", msgHash)));
        bytes memory sig = abi.encodePacked(r, s, v);

        address recovered = mgr.recoverSigner(msgHash, sig);
        assertEq(recovered, val1);
    }

    function test_superMajority() public {
        assertEq(mgr.getSuperMajority(), 3);

        mgr.setSuperMajority(2);
        assertEq(mgr.getSuperMajority(), 2);
    }

    function test_revert_unauthorizedAddValidator() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        mgr.addValidator(makeAddr("newVal"));
    }

    function test_revert_unauthorizedRemoveValidator() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        mgr.removeValidator(val1);
    }

    function test_revert_unauthorizedSetQuorum() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        mgr.setQuorum(ICorpActionTypes.ActionType.DIVIDEND, 1);
    }

    function test_getValidators() public view {
        address[] memory vals = mgr.getValidators();
        assertEq(vals.length, 3);
    }

    function test_defaultQuorums() public view {
        assertEq(mgr.getQuorum(ICorpActionTypes.ActionType.TICKER_CHANGE), 2);
        assertEq(mgr.getQuorum(ICorpActionTypes.ActionType.DIVIDEND), 3);
        assertEq(mgr.getQuorum(ICorpActionTypes.ActionType.MERGER_CASH), 4);
        assertEq(mgr.getQuorum(ICorpActionTypes.ActionType.DELISTING), 4);
    }
}
