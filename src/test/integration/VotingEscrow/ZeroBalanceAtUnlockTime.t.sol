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


contract VotingEscrowZeroBalanceAtUnlockTest is DSTest, MockSmartWalletChecker {

    CheatCodes cheats = CheatCodes(HEVM_ADDRESS);

    VotingEscrow votingEscrow;
    ERC20Mock mock20;

    uint256 constant WEEK = 86400 * 7;
    
    // try fuzzing here?
    uint256 st_initial = WEEK * 2; // max val 1 year 
    uint256 st_extend = WEEK; // max val 2 weeks 
 
    function setUp() public {
        mock20 = new ERC20Mock("Mock20", "M20", 18, 0);
        votingEscrow = new VotingEscrow(
            address(mock20),
            "name",
            "symbol",
            "0.0.0"
        );
        mock20.__mint(address(this), 10 ether);
        mock20.approve(address(votingEscrow), 10 ether);

        votingEscrow.commit_smart_wallet_checker(address(this));
        votingEscrow.apply_smart_wallet_checker();
    }

    function testCreateLockZeroBalance() public {
        uint256 expected_unlock = st_initial;

        votingEscrow.create_lock(1 ether, expected_unlock);

        uint256 actual_unlock;
        (,actual_unlock) = votingEscrow.locked(address(this));

        cheats.warp(actual_unlock - 5);
        cheats.roll(actual_unlock - 5);

        assertTrue(votingEscrow.balanceOf(address(this), block.timestamp) > 0);

        cheats.warp(actual_unlock + 5);
        cheats.roll(actual_unlock + 5);

        assertTrue(votingEscrow.balanceOf(address(this), block.timestamp) == 0);
    }

    function testIncreaseUnlockZeroBalance() public {
        uint256 expected_unlock = st_initial;

        votingEscrow.create_lock(1 ether, expected_unlock);

        uint256 initial_unlock;
        (,initial_unlock) = votingEscrow.locked(address(this));

        uint256 extended_expected_unlock = initial_unlock + st_extend;
        votingEscrow.increase_unlock_time(extended_expected_unlock);

        uint256 extended_actual_unlock;
        (,extended_actual_unlock) = votingEscrow.locked(address(this));


        cheats.warp(extended_actual_unlock - 5);
        cheats.roll(extended_actual_unlock - 5);

        assertTrue(votingEscrow.balanceOf(address(this), block.timestamp) > 0);

        cheats.warp(extended_actual_unlock + 5);
        cheats.roll(extended_actual_unlock + 5);

        assertTrue(votingEscrow.balanceOf(address(this), block.timestamp) == 0);
    }


}
