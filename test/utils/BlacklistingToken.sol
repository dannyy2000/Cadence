// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @notice A token whose `transfer` reverts for one specific blacklisted recipient, simulating
/// a real, documented category of production token (USDC/USDT can both blacklist addresses).
/// Used to prove that one queued order paying out to a blacklisted address doesn't take the
/// rest of a CadenceHook settlement down with it.
contract BlacklistingToken is MockERC20 {
    address public blacklisted;

    constructor(string memory name, string memory symbol, uint8 decimals) MockERC20(name, symbol, decimals) {}

    function setBlacklisted(address account) external {
        blacklisted = account;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blacklisted, "BlacklistingToken: recipient is blacklisted");
        return super.transfer(to, amount);
    }
}
