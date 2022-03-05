// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "ds-test/test.sol";
import {VotingEscrow} from "../../../VotingEscrow.sol";

interface CheatCodes {
    function prank(address) external;
    function expectRevert(bytes calldata) external;
}

contract VotingEscrowAdminTest is DSTest {

    CheatCodes cheats = CheatCodes(HEVM_ADDRESS);

    VotingEscrow votingEscrow;
    
    function setUp() public {
        votingEscrow = new VotingEscrow(
            address(0),
            "name",
            "symbol",
            "0.0.0"
        );
    }

    function testCommitAdminOnly() public {
        cheats.expectRevert(bytes("admin only"));
        cheats.prank(address(0xBAD));
        votingEscrow.commit_transfer_ownership(address(0xBAD));
    }

    function testApplyAdminOnly() public {
        cheats.expectRevert(bytes("admin only"));
        cheats.prank(address(0xBAD));
        votingEscrow.apply_transfer_ownership();
    }

    function testCommitTransferOwnership() public {
        votingEscrow.commit_transfer_ownership(address(0xBAD));
        assertEq(votingEscrow.admin(), address(this));
        assertEq(votingEscrow.future_admin(), address(0xBAD));
    }

    function testApplyTransferOwnership() public {
        votingEscrow.commit_transfer_ownership(address(0xBAD));
        votingEscrow.apply_transfer_ownership();
        assertEq(votingEscrow.admin(), address(0xBAD));
    }

    function testApplyWithoutCommit() public {
        cheats.expectRevert(bytes("admin not set"));
        votingEscrow.apply_transfer_ownership();
    }

}
