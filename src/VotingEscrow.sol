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
import {ReentrancyGuard} from "solidstate-solidity/utils/ReentrancyGuard.sol";
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

contract VotingEscrow is ReentrancyGuard {

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
    int128 constant iMAXTIME = 4 * 365 * 86400; // 4 years
    uint256 constant MULTIPLIER = 10 ** 18;
    bool constant allow_contract_calls = true;

    address public token;
    uint256 public supply;

    mapping(address => LockedBalance) public locked;

    uint256 public epoch;
    mapping(uint256 => Point) public point_history;  // epoch -> unsigned point
    mapping(address => Point[1000000000]) public user_point_history;  // user -> Point[user_epoch]
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
        if (allow_contract_calls) return;
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

    // @notice Get the most recently recorded ratoe of voting power decrease for `addr`
    // @param addr Address of the user wallet
    // @return Value of the slope
    function get_last_user_slope(address _addr) external view returns (int128) {
        uint256 uepoch = user_point_epoch[_addr];
        return user_point_history[_addr][uepoch].slope;
    }

    // @notice Get the timestamp for checkpoint `_idx` for `_addr`
    // @param _addr User wallet address
    // @param _idx User epoch number
    // @return Epoch time of the checkpoint
    function user_point_history__ts(address _addr, uint256 _idx) external view returns (uint256) {
        return user_point_history[_addr][_idx].ts;
    }

    // @notice Get timestamp when `_addr`'s lock finishes
    // @param _addr User wallet
    // @return Epoch time of the lock end
    function locked__end(address _addr) external view returns (uint256) {
        return locked[_addr].end;
    }

    // @notice Record global and per-user data to checkpoint
    // @param addr User's wallet address. No user checkpoint if 0x0
    // @param old_lockend Previous locked amount / end lock time for the user
    // @param new_lockend New locked amount / end lock time for the user
    function _checkpoint(address addr, LockedBalance memory old_locked, LockedBalance memory new_locked) internal {
        Point memory u_old = Point(0, 0, 0, 0);
        Point memory u_new = Point(0, 0, 0, 0);

        int128 old_dslope = 0;
        int128 new_dslope = 0;
        uint256 _epoch = epoch;

        // User checkpoint only
        if (addr != address(0)) {
            // Calculat slopes and biases
            // Kept at zero when they have to
            if (old_locked.end > block.timestamp && old_locked.amount > 0) {
                u_old.slope = old_locked.amount / iMAXTIME;
                u_old.bias = u_old.slope * int128(int256(old_locked.end - block.timestamp));
            }
            if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                u_new.slope = new_locked.amount / iMAXTIME;
                u_new.bias = u_new.slope * int128(int256(new_locked.end - block.timestamp));
            }

            // Read values of scheduled changes in the slope
            // old_locked.end can be in the past and in the future
            // new_locked.end can ONLY be in the FUTURE unless everything expired: than zeros
            old_dslope = slope_changes[old_locked.end];
            if (new_locked.end != 0) {
                if (new_locked.end == old_locked.end) {
                    new_dslope = old_dslope;
                } else {
                    new_dslope = slope_changes[new_locked.end];
                }
            }
        }

        Point memory last_point = Point(0, 0, block.timestamp, block.number);
        if (_epoch > 0) {
            last_point = point_history[_epoch];
        }
        uint256 last_checkpoint = last_point.ts;

        // initial_last_point is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out extactly from inside the contract
        Point memory initial_last_point = last_point;
        uint256 block_slope = 0; // dblock / dt
        if (block.timestamp > last_point.ts) {
            block_slope = MULTIPLIER * (block.number - last_point.blk) / (block.timestamp - last_point.ts);
        }

        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        { // scope
            // Go over weeks to fill history and calculate what the current point is
            uint256 t_i = (last_checkpoint / WEEK) * WEEK;
            for (uint i = 0; i < 255; ++i) {
                // Hopefully it won't happen that this won't get used in 5 years!
                // If it does, users will be able to withdraw but vote weight will be broken
                t_i += WEEK;
                int128 d_slope = 0;
                if (t_i > block.timestamp) {
                    t_i = block.timestamp;
                } else {
                    d_slope = slope_changes[t_i];
                }
                last_point.bias -= last_point.slope * int128(int256(t_i - last_checkpoint));
                last_point.slope += d_slope;
                if (last_point.bias < 0) {
                    // This can happen
                    last_point.bias = 0;
                }
                if (last_point.slope < 0) {
                    // This cannot happen -- just in case
                    last_point.slope = 0;
                }
                last_checkpoint = t_i;
                last_point.ts = t_i;
                last_point.blk = initial_last_point.blk + (block_slope * (t_i - initial_last_point.ts)) / MULTIPLIER;
                _epoch += 1;
                if (t_i == block.timestamp) {
                    last_point.blk = block.number;
                    break;
                } else {
                    point_history[_epoch] = last_point;
                }
            }
        } // end safety replay
        
        epoch = _epoch;
        // Now point_history is filled until t=now

        if (addr != address(0)) {
            // If last point was in this block, the slope change has been applied already
            // but in such case we have 0 slope(s)
            last_point.slope += (u_new.slope - u_old.slope);
            last_point.bias += (u_new.bias - u_old.bias);
            if (last_point.slope < 0) {
                last_point.slope = 0;
            } 
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
        }

        // Record the changed point into history
        point_history[_epoch] = last_point;

        if (addr != address(0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (old_locked.end > block.timestamp) {
                // old_dslope was <something> - u_old.slope, so we cancel that
                old_dslope += u_old.slope;
                if (new_locked.end == old_locked.end) {
                    old_dslope -= u_new.slope; // It was a new deposit, not extension
                }
                slope_changes[old_locked.end] = old_dslope;
            }

            if (new_locked.end > block.timestamp) {
                if (new_locked.end > old_locked.end) {
                    new_dslope -= u_new.slope; // old slope disappeared at this point
                    slope_changes[new_locked.end] = new_dslope;
                } // else we recorded it already in old_dslope
            }

            // Now handle user history
            uint256 user_epoch = user_point_epoch[addr] + 1;
            user_point_epoch[addr] = user_epoch;
            u_new.ts = block.timestamp;
            u_new.blk = block.number;
            user_point_history[addr][user_epoch] = u_new;
        } 

    } // end func

    // @notice Deposit and lock tokens for a user
    // @param _addr User's wallet address
    // @param _value Amount to deposit
    // @param unlock_time New Time when to unlock the token, or 0 if unchanged
    // @param locked_balance Previous locked amount / timestamp
    function _deposit_for(
        address _addr, 
        uint256 _value, 
        uint256 unlock_time, 
        LockedBalance memory locked_balance, 
        int128 deposit_type
    ) internal {

        uint256 supply_before = supply;
        supply = supply_before + _value;

        LockedBalance memory _locked = locked_balance;
        LockedBalance memory old_locked;

        (old_locked.amount, old_locked.end) = (_locked.amount, _locked.end);
        _locked.amount += int128(int256(_value));

        if (unlock_time != 0) {
            _locked.end = unlock_time;
        }
        locked[_addr] = _locked;

        // Possibilities
        // Both old_locked.end could be current or expired (> / < block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > block.timestamp (always)
        _checkpoint(_addr, old_locked, _locked);

        if (_value != 0) {
            require(IERC20(token).transferFrom(_addr, address(this), _value));
        }

        emit Deposit(_addr, _value, _locked.end, deposit_type, block.timestamp);
        emit Supply(supply_before, supply);
    }

    // @notice Record global data to checkpoint
    function checkpoint() external {
        _checkpoint(address(0), LockedBalance(0,0), LockedBalance(0,0));
    }


    // @notice Deposit `_value` tokens for `_addr` and add to the lock
    // @dev Anyone (even a smart contract) can deposit for someone else, but 
    //      cannot extend their locktime and deposit for a brand new user
    // @param _addr User's walet address
    // @param _value Amount to add to user's lock
    function deposit_for(address _addr, uint256 _value) external nonReentrant {
        LockedBalance memory _locked = locked[_addr];
        require(_value > 0, "need non-zero value");
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > block.timestamp, "Cannot add to expired lock. Withdraw");
        _deposit_for(_addr, _value, 0, locked[_addr], DEPOSIT_FOR_TYPE);
    }

    // @notice Deposit `_value` tokens for `msg.sender` and lock until `_unlock_time`
    // @param _value Amount to deposit
    // @param _unlock_time Epoch time when tokens unlock, rounded down to whole weeks
    function create_lock(uint256 _value, uint256 _unlock_time) external nonReentrant {
        assert_not_contract(msg.sender);
        uint256 unlock_time = (_unlock_time / WEEK) * WEEK; // Locktime is rounded down to weeks
        LockedBalance memory _locked = locked[msg.sender];
        require(_value > 0, "need non-zero value");
        require(_locked.amount == 0, "Withdraw old tokens first");
        require(unlock_time > block.timestamp, "Can only lock until time in the future");
        require(unlock_time <= block.timestamp + uint256(int256(iMAXTIME)), "Voting lock can be 4 years max");
        _deposit_for(msg.sender, _value, unlock_time, _locked, CREATE_LOCK_TYPE);
    }

    // @notice Deposit `_value` additional tokens for `msg.sender`
    //          without modifying the unlock time
    // @param _value Amount of tokens to deposit and add to the lock
    function increase_amount(uint256 _value) external nonReentrant {
        assert_not_contract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];

        require(_value > 0, "need non-zero value");
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > block.timestamp, "Cannot add to expired lock. Withdraw");
        
        _deposit_for(msg.sender, _value, 0, _locked, INCREASE_LOCK_AMOUNT);
    }

    // @notice Extend the unlock time for `msg.sender` to `_unlock_time`
    // @param _unlock_time New epoch time for unlocking
    function increase_unlock_time(uint256 _unlock_time) external nonReentrant {
        assert_not_contract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];
        uint256 unlock_time = (_unlock_time / WEEK) * WEEK; // Locktime is rounded down to weeks
        require(_locked.end > block.timestamp, "Lock expired");
        require(_locked.amount > 0, "Nothing is locked");
        require(unlock_time > _locked.end, "Can only increase lock duration");
        require(unlock_time <= block.timestamp + uint256(int256(iMAXTIME)), "Voting lock can be 4 years max");
        _deposit_for(msg.sender, 0, unlock_time, _locked, INCREASE_UNLOCK_TIME);
    }

    // @notice Withdraw all tokens for `msg.sender`
    // @dev Only possible if the lock has expired
    function withdraw() external nonReentrant {
        LockedBalance memory _locked = locked[msg.sender];
        require(block.timestamp >= _locked.end, "The lock didn't expire");
        uint256 value = uint256(int256(_locked.amount));

        LockedBalance memory old_locked = _locked;
        _locked.end = 0;
        _locked.amount = 0;
        locked[msg.sender] = _locked;
        uint256 supply_before = supply;
        supply = supply_before - value;

        // old_locked can have either expired <= timestamp or zero end
        // _locked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, old_locked, _locked);

        require(IERC20(token).transfer(msg.sender, value));

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(supply_before, supply);
    }

    // @notice Binary search to estimate timestamp for block number
    // @param _block Block to find
    // @param max_epoch Don't go beyond this epoch
    // @return Approximate timestamp for block
    function find_block_epoch(uint256 _block, uint256 max_epoch) internal view returns (uint256) {
        // Binary search
        uint256 _min = 0;
        uint256 _max = max_epoch;
        for (uint i = 0; i < 128; i++) {
            if (_min >= _max) break;
            uint256 _mid = (_min + _max + 1) / 2;
            
            if (point_history[_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    // @notice Get the current voting power for `msg.sender`
    // @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
    // @param addr User wallet address
    // @param _t Epoch time to return voting power at
    // @return User voting power
    function balanceOf(address addr, uint _t) external view returns (uint256) {
        uint256 _epoch = user_point_epoch[addr];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory last_point = user_point_history[addr][_epoch];
            last_point.bias -= last_point.slope * int128(int256(_t) - int256(last_point.ts));
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
            return uint256(int256(last_point.bias));
        }
    }

    // @notice Measure voting power of `addr` at block height `_block`
    // @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
    // @param addr User's wallet address
    // @param _block Block to calculate the voting power at
    // @return Voting power
    function balanceOfAt(address addr, uint256 _block) external view returns (uint256) {
        require(_block <= block.number, "invalid block");

        uint256 _min = 0;
        uint256 _max = user_point_epoch[addr];
        for (uint i = 0; i < 128; i++) {
            if (_min >= _max) break;

            uint256 _mid = (_min + _max + 1) / 2;
            if (user_point_history[addr][_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        Point memory upoint = user_point_history[addr][_min];

        uint256 max_epoch = epoch;
        uint256 _epoch = find_block_epoch(_block, max_epoch);
        Point memory point_0 = point_history[_epoch];
        uint256 d_block = 0;
        uint256 d_t = 0;

        if (_epoch <= max_epoch) {
            Point memory point_1 = point_history[_epoch + 1];
            d_block = point_1.blk - point_0.blk;
            d_t = point_1.ts - point_0.ts;
        } else {
            d_block = block.number - point_0.blk;
            d_t = block.timestamp - point_0.ts;
        }
        uint256 block_time = point_0.ts;
        if (d_block != 0) {
            block_time += uint256(int256(upoint.slope)) * uint256(int256(block.timestamp) - int256(upoint.ts));
        }

        if (upoint.bias >= 0) {
            return uint256(int256(upoint.bias));
        } else {
            return 0;
        }
    }

    // @notice Calculate total voting power at some point in the past
    // @param point the (bias/slope) to start search from
    // @param t Time to calculate the total voting power at
    // @return Total voting power at that time
    function supplyAt(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory last_point = point;
        uint256 t_i = (last_point.ts / WEEK) * WEEK;

        for (uint i = 0; i < 255; i++) {
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > t) {
                t_i = t;
            } else {
                d_slope = slope_changes[t_i];
            }

            last_point.bias -= last_point.slope * int128(int256(t_i) - int256(last_point.ts));

            if (t_i == t) break; 
            last_point.slope += d_slope;
            last_point.ts = t_i;
        }

        if (last_point.bias < 0) {
            last_point.bias = 0;
        }
        return uint256(int256(last_point.bias));

    }

    // @notice Calculate total voting power
    // @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
    // @return Total voting power
    function totalSupply() external view returns (uint256) {
        uint256 _epoch = epoch;
        Point memory last_point = point_history[_epoch];
        return supplyAt(last_point, block.timestamp);
    }

    // @notice Calculate total voting power at some point the past
    // @param _block Block to calculate the total voting power at
    // @return Total voting power at `_block`
    function totalSupplyAt(uint256 _block) external view returns (uint256) {
        require(_block <= block.number, "invalid block");
        uint256 _epoch = epoch;
        //uint256 target_epoch = 
    }

    // @notice Dummy method for Aragon compatibility
    function changeController(address _newController) external {
        require(msg.sender == controller, "controller only");
        controller = _newController;
    }

}
