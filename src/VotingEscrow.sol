// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

/**
 * Voting escrow to have time-weighted votes
 * Votes have a weight depending on time, so that users are committed
 *      to the future of (whatever they are voting for)
 * The weight in this implementation is linear, and lock cannot be more than maxtime.
 *
 * w ^
 * 1 +        /
 *   |      /
 *   |    /
 *   |  /
 *   |/
 * 0 +--------+------> time
 *       maxtime (4 years?)
 ***/


import {IERC20} from "solidstate-solidity/token/ERC20/IERC20.sol";
import {ISmartWalletChecker} from "./interfaces/ISmartWalletChecker.sol";

struct Point {
    int128 bias;
    int128 slope; // - dweight / dt
    uint256 ts;
    uint256 blk;
}
// We cannot really do block numbers per se b/c slope is per timem not per block
// and per block could be fairly bad b/c Ethereum changes blocktimes.
// What we can do is to extrapolate ***At functions

struct LockedBalance {
    int128 amount;
    uint256 end;
}

contract VotingEscrow {

    int128 constant DEPOSIT_FOR_TYPE = 0;
    int128 constant CREATE_LOCK_TYPE = 1;
    int128 constant INCREASE_LOCK_AMOUNT = 2;
    int128 constant INCREASE_UNLOCK_TIME = 3;

    event CommitOwnership(address admin);
    event ApplyOwnership(address adming);
    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 indexed locktime,
        int128 deposit_type,
        uint256 ts
    );
    event Withdraw(
        address indexed provider,
        uint256 value,
        uint256 ts
    );
    event Supply(
        uint256 prevSupply,
        uint256 supply
    );

    uint256 constant WEEK = 7 * 86400;  // all future times are rounded by week
    uint256 constant MAXTIME = 4 * 365 * 86400; // 4 years
    uint256 constant MULTIPLER = 10 ** 18;

    address public token;
    uint256 public supply;

    mapping(address => LockedBalance) public locked;

    uint256 public epoch;
    mapping(uint256 => Point) public point_history;  // epoch -> unsigned point
    mapping(address => Point[]) public user_point_history;  // user -> Point[user_epoch]
    mapping(address => uint256) public user_point_epoch;
    mapping(uint256 => int128) public slope_changes; // time -> signed slope change

    // Aragon's view methods for compatibility
    address public controller;
    bool public transfersEnabled;

    string public name;
    string public symbol;
    string public version;
    uint256 public decimals = 18; // DIFF

    // Checker for whitelisted (smart contract) wallets which are allowed to deposit
    // The goal is to prevent tokenizing the escrow
    address public future_smart_wallet_checker;
    address public smart_wallet_checker;

    address public admin; // Can and will be a smart contract
    address public future_admin;


    constructor(address token_addr, string memory _name, string memory _symbol, string memory _version) {
        admin = msg.sender;
        token = token_addr;
        point_history[0].blk = block.number;
        point_history[0].blk = block.timestamp;
        controller = msg.sender;
        transfersEnabled = true;

        /* DIFF : set as constant to 18
        uint256 _decimals = IERC20(token_addr).decimals();
        require(_decimals <= 255, "something decimals");
        decimals = _decimals;
        */

        name = _name;
        symbol = _symbol;
        version = _version;
    }


    // @notice Apply ownership transfer
    function commit_transfer_ownership(address addr) external {
        require(msg.sender == admin, "admin only");
        future_admin = addr;
        emit CommitOwnership(addr);
    }

    // @notice Apply ownership transfer
    function apply_transfer_ownership() external {
        require(msg.sender == admin, "admin only");
        address _admin = future_admin;
        require(_admin != address(0), "admin not set");
        admin = _admin;
        emit ApplyOwnership(_admin);
    }

    // @notice Set an external contract to check for approved smart contract wallets
    // @param addr Address of Smart contract checker
    function commit_smart_wallet_checker(address addr) external {
        require(msg.sender == admin, "admin only");
        future_smart_wallet_checker = addr;
    }
    
    // @notice Apply setting external contract to check approved smart contract wallets
    function apply_smart_wallet_checker() external {
        require(msg.sender == admin, "admin only");
        smart_wallet_checker = future_smart_wallet_checker;
    }
    
    // @notice Check if the call is from a whitelisted smart contract, revert if not
    // @param addr Address to be checked
    function assert_not_contract(address addr) internal {
        if (addr != tx.origin) {
            address checker = smart_wallet_checker;
            if (checker != address(0)) {
                if (ISmartWalletChecker(checker).check(addr)) {
                    return;
                }
            }
            revert("Smart contract depositors not allowed");
        }
    }


}
