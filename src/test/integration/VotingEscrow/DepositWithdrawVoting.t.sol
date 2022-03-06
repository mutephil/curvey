// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";
import {VotingEscrow} from "../../../VotingEscrow.sol";
import {ERC20Mock} from "solidstate-solidity/token/ERC20/ERC20Mock.sol";
import {MockSmartWalletChecker} from "../../mocks/SmartWalletChecker.sol";

interface CheatCodes {
    function warp(uint256) external;
    function roll(uint256) external;
    function expectRevert(bytes calldata) external;
}

contract  DepositWithdrawVotingTest is DSTest, MockSmartWalletChecker {

    CheatCodes cheats = CheatCodes(HEVM_ADDRESS);

    address[10] accounts = [
        address(0xABE),
        address(0xCADE),
        address(0xFEA),
        address(0xFACE),
        address(0xFAD),
        address(0xFEED),
        address(0xBAD),
        address(0xDAB),
        address(0xCAFE),
        address(0xBEEF)
    ];

    VotingEscrow votingEscrow;
    ERC20Mock mock20;

    uint256 constant WEEK = 86400 * 7;

    uint256 constant FOUR_YEARS = 4 * 365 * 86400;
    int128 constant iFOUR_YEARS = 4 * 365 * 86400;

    // set up accounts
    // check reverts in seperate functions 

    function setUp() public {
        mock20 = new ERC20Mock("Mock20", "M20", 18, 0);
        votingEscrow = new VotingEscrow(
            address(mock20),
            "name",
            "symbol",
            "0.0.0"
        );
        // fund account
        for (uint i = 0; i < 10; i++) {
            mock20.__mint(accounts[i], 10 ether);
        }
        mock20.__mint(address(this), 10 ether);
        mock20.approve(address(votingEscrow), 10 ether);

        votingEscrow.commit_smart_wallet_checker(address(this));
        votingEscrow.apply_smart_wallet_checker();
    }

    // create_lock
    function testCreateLockNonZeroAmount() public {
        cheats.expectRevert(bytes("need non-zero value"));
        votingEscrow.create_lock(0, 100);
    }
    function testCreateLockPendingWithdrawal() public {
        votingEscrow.create_lock(1000, 1000000);
        cheats.expectRevert(bytes("Withdraw old tokens first"));
        votingEscrow.create_lock(1000, 1000000);
    }
    function testCreateLockPastUnlockUpdate() public {
        cheats.warp(2);
        cheats.expectRevert(bytes("Can only lock until time in the future"));
        votingEscrow.create_lock(1, 1);
    }
    function testCreateLockLessThan4Years() public {
        cheats.expectRevert(bytes("Voting lock can be 4 years max"));
        votingEscrow.create_lock(1, FOUR_YEARS+WEEK+1);
    }
    function testCreateLock() public {
        votingEscrow.create_lock(10000, FOUR_YEARS);
    }


    // increase_amount
    function testIncreaseAmountNonZeroAmount() public {
        cheats.expectRevert(bytes("need non-zero value"));
        //votingEscrow.create_lock(10000, FOUR_YEARS);
        votingEscrow.increase_amount(0);
    }
    function testIncreaseAmountNonexistentLock() public {
        cheats.expectRevert(bytes("No existing lock found"));
        votingEscrow.increase_amount(1);
    }
    function testIncreaseAmountExpiredLock() public {
        votingEscrow.create_lock(10000, FOUR_YEARS);
        cheats.warp(FOUR_YEARS+WEEK+WEEK);
        cheats.expectRevert(bytes("Cannot add to expired lock. Withdraw"));
        votingEscrow.increase_amount(1);
    }


    function testIncreaseAmount() public {
        votingEscrow.create_lock(10000, FOUR_YEARS);
        votingEscrow.increase_amount(1);
    }

    // increase_unlock
    function testIncreaseUnlockTimeLockExpired() public {
        votingEscrow.create_lock(10000, WEEK);
        cheats.warp(WEEK*2 + 1);
        cheats.expectRevert(bytes("Lock expired"));
        votingEscrow.increase_unlock_time(WEEK);
    }
    function testIncreaseUnlockTimeNothingIsLocked() public {
        // have to rig state first
        /*
        votingEscrow.create_lock(10000, WEEK);
        cheats.expectRevert(bytes("Nothing is locked"));
        votingEscrow.increase_unlock_time(WEEK*2);
        */
    }
    function testIncreaseUnlockTimeOnlyIncreaseLockTime() public {
        votingEscrow.create_lock(10000, WEEK);
        cheats.expectRevert(bytes("Can only increase lock duration"));
        votingEscrow.increase_unlock_time(WEEK);
    }
    function testIncreaseUnlockTimeLessThanFourYears() public {
        votingEscrow.create_lock(10000, WEEK);
        cheats.expectRevert(bytes("Voting lock can be 4 years max"));
        votingEscrow.increase_unlock_time(FOUR_YEARS+2*WEEK);
    }
    function testIncreaseUnlockTime() public {
        votingEscrow.create_lock(10000, WEEK);
        votingEscrow.increase_unlock_time(FOUR_YEARS);
    }

    // withdraw
    function testWithdrawLockNotExpired() public {
        votingEscrow.create_lock(10000, WEEK);
        cheats.expectRevert(bytes("The lock didn't expire"));
        votingEscrow.withdraw();
    }
    function testWithdraw() public {
        votingEscrow.create_lock(10000, WEEK);
        cheats.warp(WEEK+1);
        cheats.roll(WEEK+1);
        votingEscrow.withdraw();
    }

    // checkpoint
    function testCheckpoint() public {
        votingEscrow.checkpoint();
    }

    /* Lazyingess takes over the author
    function testAdvanceTime() public {}
    function testTokenBalance() public {}
    function testEscrowCurrentBalance() public {}
    function testHistoricBalances() public {}
    */
    
}
