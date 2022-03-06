// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import {ISmartWalletChecker} from "../../interfaces/ISmartWalletChecker.sol";

abstract contract MockSmartWalletChecker is ISmartWalletChecker {
    function check(address addr) external returns (bool) {
        return address(this) == addr;
        //return true;
    }
}
