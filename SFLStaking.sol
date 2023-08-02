// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SFLStaking is
    Ownable,
    Pausable
{
    struct Policy {
        uint lockupSec;
        uint bonusPer;
    }

    struct StakeInfo {
        uint endTimestamp;
        uint realAmount;
        uint totalAmount;
        uint stakeAmount;
        uint rewardAmount;
        bool finished;
    }

    struct PoolState {
        uint timestamp;
        uint originTotal;
        uint stakeTotal;
        uint rewardTotal;
    }

    using SafeERC20 for IERC20;
    IERC20 immutable public stakeToken;

    uint256 public totalPooledOrigin;
    uint256 public totalPooledStake;
    uint256 public totalPooledReward;
    
    uint256 public earMarkedTimestamp;
    uint256 immutable public startInflationFromTimestamp;
    uint256 public inflationPerSec = 0.15854166 ether;
    uint256 public minimumStakingAmount = 0.000001 ether;
    mapping(string => Policy) public policyMap;
    PoolState[] public poolStateList;
    mapping(address => StakeInfo[]) public stakeInfoMap;

    event Stake(address indexed _from, uint256 _realAmount, uint256 _totalAmount, uint256 _stakeAmount, uint256 _startTime, uint256 _endTime, uint256 _itemIdx);
    event Unstake(address indexed _from, uint256 _realAmount, uint256 _totalAmount, uint256 _stakeAmount, uint256 _rewardAmount, uint256 _realRewardAmount);

    constructor(
        address _stakeTokenAddress,
        uint256 _startInflationFromTimestamp
    ) {
        earMarkedTimestamp = currentTime();
        stakeToken = IERC20(_stakeTokenAddress);
        startInflationFromTimestamp = _startInflationFromTimestamp;

        // init
        _updatePoolState();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function currentTime() public view virtual returns(uint256) {
        return block.timestamp;
    }

    function getItemLength(address _addr) public view returns (uint) {
        return stakeInfoMap[_addr].length;
    }

    function withdrawStakeToken(uint _amount) external onlyOwner {
        require(
            _amount <= stakeToken.balanceOf(address(this)) - _getTotalPooledReward(),
            "amount exceeds the treasury"
        );
        stakeToken.safeTransfer(msg.sender, _amount);
    }

    function setPolicy(string memory _key, uint _lockupSec, uint _bonusPer) external onlyOwner {       
        require(_lockupSec > 0, "Invlid lockupSec");
        require(_bonusPer >= 0, "Invlid bonusPer");

        policyMap[_key] = Policy({
            lockupSec: _lockupSec,
            bonusPer: _bonusPer
        });
    }

    function removePolicy(string memory _key) external onlyOwner {       
        policyMap[_key].lockupSec = 0;
        policyMap[_key].bonusPer = 0;
    }
    
    function _addStakeItem(address _addr, uint _endTimeStamp, uint _realAmount, uint _totalAmount, uint _stakeAmount) internal {
        stakeInfoMap[_addr].push(StakeInfo({
            endTimestamp: _endTimeStamp,
            realAmount: _realAmount,
            totalAmount: _totalAmount,
            stakeAmount: _stakeAmount,
            rewardAmount: 0,
            finished: false
        }));
    }

    function changeInflation(uint _inflationPerSec) external onlyOwner {
        totalPooledReward = _getTotalPooledReward();
        earMarkedTimestamp = currentTime();
        _updatePoolState();
        inflationPerSec = _inflationPerSec;
    }

    function updatePoolStateExplicitly() external {
        totalPooledReward = _getTotalPooledReward();
        earMarkedTimestamp = currentTime();
        _updatePoolState();
    }

    function changeMinimumStakeAmount(uint _amount) external onlyOwner {
        minimumStakingAmount = _amount;
    }

    function _updatePoolState() internal {
        poolStateList.push(PoolState({
            timestamp: currentTime(),
            originTotal: totalPooledOrigin,
            stakeTotal: totalPooledStake,
            rewardTotal: totalPooledReward
        }));
    }

    function findPoolState(uint _timestamp) public view returns (PoolState memory poolstate) {
        require(poolStateList.length > 0, "No pool state available");

        uint lastIndex = poolStateList.length - 1;
        uint low = 0;
        uint high = lastIndex;

        // Edge cases
        if (_timestamp >= poolStateList[lastIndex].timestamp) {
            return poolStateList[lastIndex];
        }

        require(_timestamp >= poolStateList[0].timestamp, "Invalid timestamp");

        // Binary search
        while (low < high) {
            uint mid = (low + high + 1) / 2;
            if (poolStateList[mid].timestamp <= _timestamp) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }

        return poolStateList[low];
    }

    function stake(string memory _policyKey) external payable whenNotPaused returns(uint256) {
        require(msg.value >= minimumStakingAmount, "Minimum amount");
        require(policyMap[_policyKey].lockupSec != 0, "Policy is empty");

        totalPooledReward = _getTotalPooledReward();
        earMarkedTimestamp = currentTime();
        uint stakeAmount = msg.value * (100 + policyMap[_policyKey].bonusPer) / 100;
        uint256 amountOfStakingToken = _convertOriginTokenToStaking(stakeAmount, totalPooledStake, _getTotalPooledOriginAndReward());
        totalPooledOrigin += stakeAmount;
        totalPooledStake += amountOfStakingToken;

        uint stakeTime = (earMarkedTimestamp < startInflationFromTimestamp ? startInflationFromTimestamp : earMarkedTimestamp);
        _updatePoolState();
        _addStakeItem(msg.sender, stakeTime + policyMap[_policyKey].lockupSec, msg.value, stakeAmount, amountOfStakingToken);

        emit Stake(msg.sender, msg.value, stakeAmount, amountOfStakingToken, stakeTime, stakeTime + policyMap[_policyKey].lockupSec, stakeInfoMap[msg.sender].length - 1);
        return amountOfStakingToken;
    }

    function unstake(uint256 _infoIdx) external whenNotPaused returns(uint256) {
        require(stakeInfoMap[msg.sender].length > _infoIdx, "Invalid item idx");
        StakeInfo storage stakeInfo = stakeInfoMap[msg.sender][_infoIdx];
        require(!stakeInfo.finished, "Already finished");
        require(stakeInfo.endTimestamp <= currentTime(), "Unable to withdraw");

        totalPooledReward = _getTotalPooledReward();
        earMarkedTimestamp = currentTime();
        PoolState memory poolState = findPoolState(stakeInfo.endTimestamp);
        uint _totalPooledRewardFromPoolState = _getTotalPooledOriginAndRewardFromPool(poolState, stakeInfo.endTimestamp);

        uint256 amountOfRewardToken = _convertStakingTokenToOriginAndReward(stakeInfo.stakeAmount, poolState.stakeTotal, _totalPooledRewardFromPoolState);
        uint256 realAmountOfRewardToken = _convertStakingTokenToOriginAndReward(stakeInfo.stakeAmount, totalPooledStake, _getTotalPooledOriginAndReward());
        uint256 reward = amountOfRewardToken - stakeInfo.totalAmount;
        uint256 realReward = realAmountOfRewardToken - stakeInfo.totalAmount;
        stakeInfo.rewardAmount = reward;
        stakeInfo.finished = true;
        totalPooledOrigin -= stakeInfo.totalAmount;
        totalPooledStake -= stakeInfo.stakeAmount;
        totalPooledReward -= realReward;

        address payable sender = payable(msg.sender);
        sender.transfer(stakeInfo.realAmount);
        stakeToken.safeTransfer(msg.sender, reward);

        _updatePoolState();
        emit Unstake(msg.sender, stakeInfo.realAmount, stakeInfo.totalAmount, stakeInfo.stakeAmount, reward, realReward);
        return reward;
    }

    function getTotalPooledOriginForDisplay() public view returns(uint) {
        return totalPooledOrigin;
    }

    function getTotalPooledOriginAndReward() public view returns(uint256) {
        return _getTotalPooledOriginAndReward();
    }

    function getTotalPooledReward() public view returns(uint256) {
        return _getTotalPooledReward();
    }

    function expectedEarning(uint256 _originToken, string memory _policyKey) public view returns(uint256) {
        require(_originToken > 0, "Origin token");
        require(policyMap[_policyKey].lockupSec != 0, "Policy is empty");

        uint _stakeAmount = _originToken * (100 + policyMap[_policyKey].bonusPer) / 100;
        uint _stakeToken = convertOriginTokenToStaking(_stakeAmount);
        uint _totalPooledStake = totalPooledStake + _stakeToken;
        uint _endTime = (currentTime() < startInflationFromTimestamp ? startInflationFromTimestamp : currentTime()) + policyMap[_policyKey].lockupSec;
        uint _totalPooledOriginAfterLockupTime = _stakeAmount + _getTotalPooledOriginAndRewardAtTime(_endTime);

        uint256 amountOfRewardToken = _convertStakingTokenToOriginAndReward(_stakeToken, _totalPooledStake, _totalPooledOriginAfterLockupTime);
        return amountOfRewardToken - _stakeAmount;
    }

    function earning(address _addr, uint _infoIdx) public view returns(uint256) {
        require(stakeInfoMap[_addr].length > _infoIdx, "Invalid item idx");
        StakeInfo storage stakeInfo = stakeInfoMap[_addr][_infoIdx];
        if (stakeInfo.finished) {
            return stakeInfo.rewardAmount;
        }

        uint _totalPooledStake = totalPooledStake;
        uint _totalPooledOriginAndReward = _getTotalPooledOriginAndReward();
        if (stakeInfo.endTimestamp < currentTime()) {
            PoolState memory poolState = findPoolState(stakeInfo.endTimestamp);
            _totalPooledStake = poolState.stakeTotal;
            _totalPooledOriginAndReward = _getTotalPooledOriginAndRewardFromPool(poolState, stakeInfo.endTimestamp);
        }

        uint256 amountOfRewardToken = _convertStakingTokenToOriginAndReward(stakeInfo.stakeAmount, _totalPooledStake, _totalPooledOriginAndReward);
        return amountOfRewardToken - stakeInfo.totalAmount;
    }

    function convertOriginTokenToStaking(uint256 _originToken) public view returns(uint256) {
        return _convertOriginTokenToStaking(_originToken, totalPooledStake, _getTotalPooledOriginAndReward());
    }

    function convertStakingTokenToOriginAndReward(uint256 _stakingToken) public view returns(uint256) {
        return _convertStakingTokenToOriginAndReward(_stakingToken, totalPooledStake, _getTotalPooledOriginAndReward());
    }

    function _convertOriginTokenToStaking(
        uint256 _originToken,
        uint256 _totalStaking,
        uint256 _totalOrigin
    ) internal pure returns(uint256) {
        _totalStaking = _totalStaking == 0 ? 1 : _totalStaking;
        _totalOrigin = _totalOrigin == 0 ? 1 : _totalOrigin;
        return (_originToken * _totalStaking) / _totalOrigin;
    }

    function _convertStakingTokenToOriginAndReward(
        uint256 _stakingToken,
        uint256 _totalStaking,
        uint256 _totalOrigin
    ) internal pure returns(uint256) {
        _totalStaking = _totalStaking == 0 ? 1 : _totalStaking;
        _totalOrigin = _totalOrigin == 0 ? 1 : _totalOrigin;
        return (_stakingToken * _totalOrigin) / _totalStaking;
    }

    function _getTotalPooledOriginAndReward() internal view returns(uint256) {
        return totalPooledOrigin + _getTotalPooledReward();
    }

    function _getTotalPooledReward() internal view returns (uint256) {
        if (currentTime() <= startInflationFromTimestamp) return 0;
        if (totalPooledStake == 0) return 0;

        uint256 markedTimeStamp = earMarkedTimestamp < startInflationFromTimestamp ? startInflationFromTimestamp : earMarkedTimestamp;
        uint256 _inflation = inflationPerSec * (currentTime() - markedTimeStamp);
        uint256 _contractBalance = stakeToken.balanceOf(address(this));
        if (totalPooledReward + _inflation > _contractBalance) return _contractBalance;
        return totalPooledReward + _inflation;    
    }

    function _getTotalPooledOriginAndRewardAtTime(uint _timeStamp) internal view returns (uint256) {
        uint _earMarkedTimestamp = earMarkedTimestamp;
        if (_earMarkedTimestamp < startInflationFromTimestamp && currentTime() < startInflationFromTimestamp) {
            _earMarkedTimestamp = startInflationFromTimestamp;
        } else if (totalPooledStake == 0) {
            _earMarkedTimestamp = currentTime();
        }

        uint256 _inflation = inflationPerSec * (_timeStamp - _earMarkedTimestamp);
        uint256 _contractBalance = stakeToken.balanceOf(address(this));
        if (totalPooledReward + _inflation > _contractBalance) return _contractBalance;
        return totalPooledOrigin + totalPooledReward + _inflation;
    }

    function _getTotalPooledOriginAndRewardFromPool(PoolState memory _poolState, uint _timeStamp) internal view returns (uint256) {
        if (_timeStamp <= startInflationFromTimestamp) return 0;
        if (_timeStamp < _poolState.timestamp) return _poolState.originTotal;

        uint256 _inflation = inflationPerSec * (_timeStamp - _poolState.timestamp);
        uint256 _contractBalance = stakeToken.balanceOf(address(this));
        if (_poolState.rewardTotal + _inflation > _contractBalance) return _contractBalance;
        return _poolState.originTotal + _poolState.rewardTotal + _inflation;
    }

    function getTimeStamp() public view returns (uint256) {
        return block.timestamp;
    }

}