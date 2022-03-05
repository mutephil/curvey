// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

interface ISmartWalletChecker {
    function check(address addr) external returns (bool);
}
