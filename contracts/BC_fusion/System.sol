// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

contract System {
  address public constant VALIDATOR_CONTRACT_ADDR = 0x0000000000000000000000000000000000001000;
  address public constant STAKE_HUB_ADDR = 0x0000000000000000000000000000000000002002;

  modifier onlyValidatorContract() {
    require(msg.sender == VALIDATOR_CONTRACT_ADDR, "the message sender must be validatorSet contract");
    _;
  }

  modifier onlyStakeHub() {
    require(msg.sender == STAKE_HUB_ADDR, "the msg sender must be stakeHub");
    _;
  }
}
