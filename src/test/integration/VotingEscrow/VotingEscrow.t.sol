// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";
import {VotingEscrow} from "../../../VotingEscrow.sol";
import {ERC20Mock} from "solidstate-solidity/token/ERC20/ERC20Mock.sol";
import {MockSmartWalletChecker} from "../../mocks/SmartWalletChecker.sol";

interface CheatCodes {
    function warp(uint256) external;
    function roll(uint256) external;
    function prank(address) external;
    function expectRevert(bytes calldata) external;
}

contract VotingEscrowTest is DSTest, MockSmartWalletChecker {

    CheatCodes cheats = CheatCodes(HEVM_ADDRESS);

    address alice = address(0xABE);
    address bob = address(0xCADE);

    VotingEscrow votingEscrow;
    ERC20Mock mock20;

    uint256 constant H = 3600;
    uint256 constant DAY = 86400;
    uint256 constant WEEK = 7 * DAY;
    uint256 constant MAXTIME = 126144000;
    uint256 constant TOL = 10 ** 4 * 120 / WEEK;
 
    function setUp() public {
        mock20 = new ERC20Mock("Mock20", "M20", 18, 0);
        votingEscrow = new VotingEscrow(
            address(mock20),
            "name",
            "symbol",
            "0.0.0"
        );

        // fund account
        mock20.__mint(alice, 1000 ether);
        mock20.__mint(bob, 1000 ether);
        mock20.__mint(address(this), 1000 ether);
        mock20.approve(address(votingEscrow), 1000 ether);
        cheats.prank(alice);
        mock20.approve(address(votingEscrow), 1000 ether);
        cheats.prank(bob);
        mock20.approve(address(votingEscrow), 1000 ether);

        //votingEscrow.commit_smart_wallet_checker(address(this));
        //votingEscrow.apply_smart_wallet_checker();

    }

    function testVotingPowers() public {
        uint256 amount = 1000 ether;
        assertEq(votingEscrow.totalSupply(), 0);
        assertEq(votingEscrow.balanceOf(alice, block.timestamp), 0);
        assertEq(votingEscrow.balanceOf(bob, block.timestamp), 0);

        cheats.prank(alice);
        votingEscrow.create_lock(amount, WEEK); 

        uint previous_supply = votingEscrow.totalSupply();

        for (uint i = 0; i < 7; i++) {
            cheats.warp(H*24*i); cheats.roll(H*24*i);

            assertTrue(approx(votingEscrow.totalSupply(), amount / (MAXTIME * (WEEK - 2 * H*i - block.timestamp)), TOL));
            assertTrue(approx(votingEscrow.balanceOf(alice, block.timestamp), amount / (MAXTIME * (WEEK - 2 * H*i - block.timestamp)), TOL));

            assertEq(votingEscrow.totalSupply(), votingEscrow.balanceOf(alice, block.timestamp));
            assertEq(votingEscrow.balanceOf(bob, block.timestamp), 0);
            
        }

        cheats.warp(WEEK);
        cheats.roll(WEEK);

        assertEq(votingEscrow.totalSupply(), 0);
        assertEq(votingEscrow.balanceOf(alice, block.timestamp), 0);
        assertEq(votingEscrow.balanceOf(bob, block.timestamp), 0);

    }

    function testVotingPowerMultiUser() external {
        uint256 amount = 1000 ether;

        assertEq(votingEscrow.totalSupply(), 0);
        assertEq(votingEscrow.balanceOf(alice, block.timestamp), 0);
        assertEq(votingEscrow.balanceOf(bob, block.timestamp), 0);
        

        cheats.prank(alice);
        votingEscrow.create_lock(amount, MAXTIME); 

        cheats.prank(bob);
        votingEscrow.create_lock(amount, WEEK*2); 

        for (uint i = 0; i < i; i++) {

            cheats.warp(H*24*i); cheats.roll(H*24*i);

            assertEq(
                votingEscrow.totalSupply(), 
                votingEscrow.balanceOf(alice, block.timestamp) + votingEscrow.balanceOf(bob, block.timestamp)
            );

            assertEq(
                votingEscrow.totalSupply(), 
                votingEscrow.balanceOfAt(alice, block.timestamp) + votingEscrow.balanceOfAt(bob, block.timestamp)
            );
        }
    }


    // https://github.com/curvefi/curve-dao-contracts/tests/conftest.py#22
    function approx(uint256 a, uint256 b, uint256 precision) internal returns (bool) {
        return (2 * (a > b ? a - b : b - a) / (a + b)) <= precision;
    }

}
