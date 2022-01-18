// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "./owner/Operator.sol";

/*
 __    __   _______  ___      ___  ____________   __    __   _______   ________
|  |  |  | |   ____| \  \    /  / |____    ____| |  |  |  | |   ____| |   ____  \ 
|  |__|  | |  |___    \  \__/  /       |  |      |  |__|  | |  |___   |  |   /  /
|   __   | |   ___|    |  __  |        |  |      |   __   | |   ___|  |  |  /__/
|  |  |  | |  |____   /  /  \  \       |  |      |  |  |  | |  |____  |  |  \  \ 
|__|  |__| |_______| /__/    \__\      |__|      |__|  |__| |_______| |__|   \__\ 

*/
contract HexShares is ERC20Burnable, Operator {
    using SafeMath for uint256;

    // TOTAL MAX SUPPLY = 70,000 SHARES
    uint256 public constant FARMING_POOL_REWARD_ALLOCATION = 55000 ether;
    uint256 public constant DAO_FUND_POOL_ALLOCATION = 10000 ether;
    uint256 public constant TEAM_FUND_POOL_ALLOCATION = 5000 ether;

    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public startTime;
    uint256 public endTime;

    uint256 public daoFundRewardRate;
    uint256 public teamFundRewardRate;

    address public daoFund;
    address public teamFund;

    uint256 public daoFundLastClaimed;
    uint256 public teamFundLastClaimed;

    bool public rewardPoolDistributed = false;

    constructor(uint256 _startTime, address _daoFund, address _teamFund) public ERC20("HexShares", "HEXS") {
        _mint(msg.sender, 1 ether); // mint 1 HERMES Share for initial pools deployment

        startTime = _startTime;
        endTime = startTime + VESTING_DURATION;

        daoFundLastClaimed = startTime;
        teamFundLastClaimed = startTime;

        daoFundRewardRate = DAO_FUND_POOL_ALLOCATION.div(VESTING_DURATION);
        teamFundRewardRate = TEAM_FUND_POOL_ALLOCATION.div(VESTING_DURATION);

        require(_teamFund != address(0), "Address cannot be 0");
        teamFund = _teamFund;

        require(_daoFund != address(0), "Address cannot be 0");
        daoFund = _daoFund;
    }

    function setDaoFund(address _daoFund) external {
        require(msg.sender == teamFund, "!team");
        daoFund = _daoFund;
    }


    function setTeamFund(address _teamFund) external {
        require(msg.sender == teamFund, "!team");
        require(_teamFund != address(0), "zero");
        teamFund = _teamFund;
    }

    function unclaimedTreasuryFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (daoFundLastClaimed >= _now) return 0;
        _pending = _now.sub(daoFundLastClaimed).mul(daoFundRewardRate);
    }


    function unclaimedTeamFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (teamFundLastClaimed >= _now) return 0;
        _pending = _now.sub(teamFundLastClaimed).mul(teamFundRewardRate);
    }

    /**
     * @dev Claim pending rewards to dao and team fund
     */
    function claimRewards() external {
        uint256 _pending = unclaimedTreasuryFund();
        if (_pending > 0 && daoFund != address(0)) {
            _mint(daoFund, _pending);
            daoFundLastClaimed = block.timestamp;
        }
        _pending = unclaimedTeamFund();
        if (_pending > 0 && teamFund != address(0)) {
            _mint(teamFund, _pending);
            teamFundLastClaimed = block.timestamp;
        }
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(address _farmingIncentiveFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, FARMING_POOL_REWARD_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
