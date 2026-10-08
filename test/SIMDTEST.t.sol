// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SIMDTEST} from "../src/SIMDTEST.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SIMDTESTTest is Test {
    SIMDTEST token;

    function setUp() public {
        token = new SIMDTEST();
    }

    function test_FactoryReceivesWholeFixedSupply() public view {
        assertEq(token.name(), "SIMDTEST");
        assertEq(token.symbol(), "SIMDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FactoryAndPoolTransfersHaveNoTax(uint256 raw) public {
        uint256 amount = bound(raw, 0, 1e27);
        address manager = makeAddr("settlement recipient");
        address router = makeAddr("router");
        token.approve(router, amount);
        vm.prank(router);
        assertTrue(token.transferFrom(address(this), manager, amount));
        assertEq(token.balanceOf(manager), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.allowance(address(this), router), 0);
        vm.prank(manager);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_NoPostDeploymentMintOrAdminSelectors() public {
        string[9] memory selectors = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setFee(uint256)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool success,) = address(token).call(abi.encodeWithSignature(selectors[i], address(this), 1e27));
            assertFalse(success);
            assertEq(token.totalSupply(), 1e27);
        }
    }

    function test_RejectOverspendAndMissingAllowance() public {
        address receiver = makeAddr("receiver");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 1e27, 1e27 + 1)
        );
        token.transfer(receiver, 1e27 + 1);
        vm.prank(receiver);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, receiver, 0, 1));
        token.transferFrom(address(this), receiver, 1);
    }
}
