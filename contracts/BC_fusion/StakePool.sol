// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/structs/DoubleEndedQueueUpgradeable.sol";

import "./StBNB.sol";
import "../System.sol";

interface IStakeHub {
    function isPaused() external view returns (bool);
    function getUnbondTime() external view returns (uint256);
}

contract StakePool is System, StBNB {
    using DoubleEndedQueueUpgradeable for DoubleEndedQueueUpgradeable.Bytes32Deque;

    uint256 public constant MAX_CLAIM_NUMBER = 20;

    /*----------------- storage -----------------*/
    address public validator;

    uint256 private _totalReceivedReward; // just for statistics
    uint256 private _totalPooledBNB; // total reward plus total BNB staked in the pool

    // hash of the unbond request => unbond request
    mapping(bytes32 => UnbondRequest) private _unbondRequests;
    // user => unbond request queue(hash of the request)
    mapping(address => DoubleEndedQueueUpgradeable.Bytes32Deque) private _unbondRequestsQueue;
    // user => locked shares
    mapping(address => uint256) private _lockedShares;
    // user => personal unbond sequence
    mapping(address => uint256) private _unbondSequence;

    struct UnbondRequest {
        uint256 sharesAmount;
        uint256 unlockTime;
    }

    /*----------------- events -----------------*/
    event Delegated(address indexed sender, uint256 sharesAmount, uint256 bnbAmount);
    event RewardReceived(uint256 bnbAmount);
    event UnbondRequested(address indexed sender, uint256 sharesAmount, uint256 unlockTime);
    event UnbondClaimed(address indexed sender, uint256 sharesAmount, uint256 bnbAmount);

    /*----------------- modifiers -----------------*/
    modifier onlyStakeHub() {
        address sender = _msgSender();
        require(sender == STAKE_HUB_ADDR, "NOT_STAKE_HUB");
        _;
    }

    modifier onlyValidatorSet() {
        address sender = _msgSender();
        require(sender == VALIDATOR_CONTRACT_ADDR, "NOT_VALIDATOR_SET");
        _;
    }

    modifier whenNotPaused() {
        require(!IStakeHub(STAKE_HUB_ADDR).isPaused(), "CONTRACT_IS_STOPPED");
        _;
    }

    /*----------------- external functions -----------------*/
    function initialize(address _validator, uint256 _selfDelegateAmt) public initializer {
        validator = _validator;

        _bootstrapInitialHolder(_selfDelegateAmt);
    }

    function delegate(
        address _delegator,
        uint256 _bnbAmount
    ) external payable onlyStakeHub whenNotPaused returns (uint256) {
        return _stake(_delegator, _bnbAmount);
    }

    function undelegate(address _delegator, uint256 _sharesAmount) external onlyStakeHub whenNotPaused returns (uint256) {
        require(_sharesAmount != 0, "ZERO_UNDELEGATE");
        require(_sharesAmount <= _sharesOf(_delegator), "INSUFFICIENT_BALANCE");

        // lock the tokens
        _transfer(_delegator, address(this), _sharesAmount);
        _lockedShares[_delegator] += _sharesAmount;

        // add to the queue
        _unbondSequence[_delegator] += 1; // increase the sequence first to avoid zero sequence
        bytes32 hash = keccak256(abi.encodePacked(_delegator, _unbondSequence[_delegator]));

        uint256 unlockTime = block.timestamp + IStakeHub(STAKE_HUB_ADDR).getUnbondTime();
        UnbondRequest memory request =
                        UnbondRequest({sharesAmount: _sharesAmount, unlockTime: unlockTime});
         _unbondRequests[hash] = request;
        _unbondRequestsQueue[_delegator].pushBack(hash);

        emit UnbondRequested(_delegator, _sharesAmount, request.unlockTime);
        return unlockTime;
    }

    function claim(address _delegator, uint256 number) external onlyStakeHub whenNotPaused returns (uint256) {
        require(_unbondRequestsQueue[_delegator].length() != 0, "NO_UNBOND_REQUEST");
        // number == 0 means claim all
        if (number == 0) {
            number = _unbondRequestsQueue[_delegator].length();
        }
        if (number > _unbondRequestsQueue[_delegator].length()) {
            number = _unbondRequestsQueue[_delegator].length();
        }
        require(number <= MAX_CLAIM_NUMBER, "TOO_MANY_REQUESTS"); // prevent too many loop in one transaction

        uint256 totalShares;
        while (number != 0) {
            bytes32 hash = _unbondRequestsQueue[_delegator].peekFront();
            UnbondRequest memory request = _unbondRequests[hash];
            if (block.timestamp < request.unlockTime) {
                break;
            }
            // request is non-existed(should not happen)
            if (request.sharesAmount == 0 && request.unlockTime == 0) {
                continue;
            }

            // remove from the queue
            _unbondRequestsQueue[_delegator].popFront();
            delete _unbondRequests[hash];

            totalShares += request.sharesAmount;
            number -= 1;
        }

        // unlock and burn the shares
        _lockedShares[_delegator] -= totalShares;
        uint256 totalBnbAmount = getPooledBNBByShares(totalShares);
        _burn(address(this), totalShares);
        emit UnbondClaimed(_delegator, totalShares, totalBnbAmount);

        _totalPooledBNB -= totalBnbAmount;
        return totalBnbAmount;
    }

    function distributeReward(uint256 _bnbAmount) external onlyValidatorSet {
        _totalReceivedReward += _bnbAmount;
        _totalPooledBNB += _bnbAmount;
        emit RewardReceived(_bnbAmount);
    }

    function felony(uint256 _bnbAmount) external onlyValidatorSet {
        _totalPooledBNB -= _bnbAmount;
        uint256 sharesAmount = getSharesByPooledBNB(_bnbAmount);
        _burn(validator, sharesAmount);
    }

    /*----------------- view functions -----------------*/
    function totalReceivedReward() external view returns (uint256) {
        return _getTotalReceivedReward();
    }

    function totalPooledBNB() external view returns (uint256) {
        return _getTotalPooledBNB();
    }

    function lockedShares(address _delegator) external view returns (uint256) {
        return _lockedShares[_delegator];
    }

    /*----------------- internal functions -----------------*/
    /**
     * @dev Process user deposit, mints liquid tokens and increase the pool staked BNB
     * @param _delegator address of the delegator.
     * @param _bnbAmount amount of BNB to stake.
     * @return amount of StBNB generated
     */
    function _stake(address _delegator, uint256 _bnbAmount) internal returns (uint256) {
        require(_bnbAmount != 0, "ZERO_DEPOSIT");

        uint256 sharesAmount = getSharesByPooledBNB(_bnbAmount);
        _totalPooledBNB += _bnbAmount;
        emit Delegated(_delegator, sharesAmount, _bnbAmount);

        _mint(_delegator, sharesAmount);
        return sharesAmount;
    }

    function _bootstrapInitialHolder(uint256 _initAmount) internal {
        assert(validator != address(0));
        assert(_getTotalShares() == 0);

        // mint initial tokens to the validator
        // shares is equal to the amount of BNB staked
        _totalPooledBNB = _initAmount;
        emit Delegated(validator, _initAmount, _initAmount);
        _mint(validator, _initAmount);
    }

    function _getTotalPooledBNB() internal view override returns (uint256) {
        return _totalPooledBNB;
    }

    function _getTotalReceivedReward() internal view returns (uint256) {
        return _totalReceivedReward;
    }
}
