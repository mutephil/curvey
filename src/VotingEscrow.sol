// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

struct Point {
    int128 bias;
    int128 slope;
    uint256 ts;
    uint256 blk;
}

struct LockedBalance {
    int128 amount;
    uint256 end;
}

contract VotingEscrow {

}
