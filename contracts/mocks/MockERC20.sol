//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../ERC20.sol";

contract MockERC20 is ERC20 {
  constructor() {
    _mint(msg.sender, 10000e18);
  }
}
