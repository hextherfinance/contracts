// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/IHexGate.sol";

/*
 __    __   _______  ___      ___  ____________   __    __   _______   ________
|  |  |  | |   ____| \  \    /  / |____    ____| |  |  |  | |   ____| |   ____  \ 
|  |__|  | |  |___    \  \__/  /       |  |      |  |__|  | |  |___   |  |   /  /
|   __   | |   ___|    |  __  |        |  |      |   __   | |   ___|  |  |  /__/
|  |  |  | |  |____   /  /  \  \       |  |      |  |  |  | |  |____  |  |  \  \ 
|__|  |__| |_______| /__/    \__\      |__|      |__|  |__| |_______| |__|   \__\ 

*/
contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // core components
    address public hexther;
    address public bbond;
    address public bshare;

    address public hexGate;
    address public hextherOracle;

    // price
    uint256 public hextherPriceOne;
    uint256 public hextherPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of HEXTHER price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochHextherPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra HEXTHER during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public teamFund;
    uint256 public teamFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 hextherAmount, uint256 bondAmount);
    event BoughtBonds(address indexed from, uint256 hextherAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event HexGateFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event TeamFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition() {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch() {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getHextherPrice() > hextherPriceCeiling) ? 0 : getHextherCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator() {
        require(
            IBasisAsset(hexther).operator() == address(this) &&
                IBasisAsset(bbond).operator() == address(this) &&
                IBasisAsset(bshare).operator() == address(this) &&
                Operator(hexGate).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized() {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getHextherPrice() public view returns (uint256 hextherPrice) {
        try IOracle(hextherOracle).consult(hexther, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult HEXTHER price from the oracle");
        }
    }

    function getHextherUpdatedPrice() public view returns (uint256 _hextherPrice) {
        try IOracle(hextherOracle).twap(hexther, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult HEXTHER price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableHextherLeft() public view returns (uint256 _burnableHextherLeft) {
        uint256 _hextherPrice = getHextherPrice();
        if (_hextherPrice <= hextherPriceOne) {
            uint256 _hextherSupply = getHextherCirculatingSupply();
            uint256 _bondMaxSupply = _hextherSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(bbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableHexther = _maxMintableBond.mul(_hextherPrice).div(1e18);
                _burnableHextherLeft = Math.min(epochSupplyContractionLeft, _maxBurnableHexther);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _hextherPrice = getHextherPrice();
        if (_hextherPrice > hextherPriceCeiling) {
            uint256 _totalHexther = IERC20(hexther).balanceOf(address(this));
            uint256 _rate = getBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalHexther.mul(1e18).div(_rate);
            }
        }
    }

    function getBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _hextherPrice = getHextherPrice();
        if (_hextherPrice <= hextherPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = hextherPriceOne;
            } else {
                uint256 _bondAmount = hextherPriceOne.mul(1e18).div(_hextherPrice); // to burn 1 HEXTHER
                uint256 _discountAmount = _bondAmount.sub(hextherPriceOne).mul(discountPercent).div(10000);
                _rate = hextherPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function getBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _hextherPrice = getHextherPrice();
        if (_hextherPrice > hextherPriceCeiling) {
            uint256 _hextherPricePremiumThreshold = hextherPriceOne.mul(premiumThreshold).div(100);
            if (_hextherPrice >= _hextherPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _hextherPrice.sub(hextherPriceOne).mul(premiumPercent).div(10000);
                _rate = hextherPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = hextherPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _hexther,
        address _bbond,
        address _bshare,
        address _hextherOracle,
        address _hexGate,
        uint256 _startTime
    ) public notInitialized {
        hexther = _hexther;
        bbond = _bbond;
        bshare = _bshare;
        hextherOracle = _hextherOracle;
        hexGate = _hexGate;
        startTime = _startTime;

        hextherPriceOne = 10**17; // This is to allow a PEG of 1 HEXTHER per 0.1 BNB
        hextherPriceCeiling = hextherPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 10000 ether, 15000 ether, 20000 ether, 25000 ether, 50000 ether, 100000 ether, 200000 ether, 500000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for hexGate
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn HEXTHER and mint tBOND)
        maxDebtRatioPercent = 4500; // Upto 35% supply of tBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 0;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(hexther).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setHexGate(address _hexGate) external onlyOperator {
        hexGate = _hexGate;
    }

    function setHextherOracle(address _hextherOracle) external onlyOperator {
        hextherOracle = _hextherOracle;
    }

    function setHextherPriceCeiling(uint256 _hextherPriceCeiling) external onlyOperator {
        require(_hextherPriceCeiling >= hextherPriceOne && _hextherPriceCeiling <= hextherPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        hextherPriceCeiling = _hextherPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function setBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _teamFund,
        uint256 _teamFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_teamFund != address(0), "zero");
        require(_teamFundSharedPercent <= 700, "out of range"); // <= 7%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        teamFund = _teamFund;
        teamFundSharedPercent = _teamFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= hextherPriceCeiling, "_premiumThreshold exceeds hextherPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateHextherPrice() internal {
        try IOracle(hextherOracle).update() {} catch {}
    }

    function getHextherCirculatingSupply() public view returns (uint256) {
        IERC20 hextherErc20 = IERC20(hexther);
        uint256 totalSupply = hextherErc20.totalSupply();
        uint256 balanceExcluded = 0;
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _hextherAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_hextherAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 hextherPrice = getHextherPrice();
        require(hextherPrice == targetPrice, "Treasury: HEXTHER price moved");
        require(
            hextherPrice < hextherPriceOne, // price < $0.1
            "Treasury: hextherPrice not eligible for bond purchase"
        );

        require(_hextherAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = getBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _hextherAmount.mul(_rate).div(1e18);
        uint256 hextherSupply = getHextherCirculatingSupply();
        uint256 newBondSupply = IERC20(bbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= hextherSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(hexther).burnFrom(msg.sender, _hextherAmount);
        IBasisAsset(bbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_hextherAmount);
        _updateHextherPrice();

        emit BoughtBonds(msg.sender, _hextherAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 hextherPrice = getHextherPrice();
        require(hextherPrice == targetPrice, "Treasury: HEXTHER price moved");
        require(
            hextherPrice > hextherPriceCeiling, // price > $1.01
            "Treasury: hextherPrice not eligible for bond purchase"
        );

        uint256 _rate = getBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _hextherAmount = _bondAmount.mul(_rate).div(1e18);
        require(IERC20(hexther).balanceOf(address(this)) >= _hextherAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _hextherAmount));

        IBasisAsset(bbond).burnFrom(msg.sender, _bondAmount);
        IERC20(hexther).safeTransfer(msg.sender, _hextherAmount);

        _updateHextherPrice();

        emit RedeemedBonds(msg.sender, _hextherAmount, _bondAmount);
    }

    function _sendToHexGate(uint256 _amount) internal {
        IBasisAsset(hexther).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(hexther).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _teamFundSharedAmount = 0;
        if (teamFundSharedPercent > 0) {
            _teamFundSharedAmount = _amount.mul(teamFundSharedPercent).div(10000);
            IERC20(hexther).transfer(teamFund, _teamFundSharedAmount);
            emit TeamFundFunded(now, _teamFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_teamFundSharedAmount);

        IERC20(hexther).safeApprove(hexGate, 0);
        IERC20(hexther).safeApprove(hexGate, _amount);
        IHexGate(hexGate).allocateSeigniorage(_amount);
        emit HexGateFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _hextherSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_hextherSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateHextherPrice();
        previousEpochHextherPrice = getHextherPrice();
        uint256 hextherSupply = getHextherCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToHexGate(hextherSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochHextherPrice > hextherPriceCeiling) {
                // Expansion ($HEXTHER Price > 1 $ETH): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(bbond).totalSupply();
                uint256 _percentage = previousEpochHextherPrice.sub(hextherPriceOne);
                uint256 _savedForBond;
                uint256 _savedForHexGate;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(hextherSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForHexGate = hextherSupply.mul(_percentage).div(1e18);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = hextherSupply.mul(_percentage).div(1e18);
                    _savedForHexGate = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForHexGate);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForHexGate > 0) {
                    _sendToHexGate(_savedForHexGate);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(hexther).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(hexther), "hexther");
        require(address(_token) != address(bbond), "bond");
        require(address(_token) != address(bshare), "share");
        _token.safeTransfer(_to, _amount);
    }

    function hexGateSetOperator(address _operator) external onlyOperator {
        IHexGate(hexGate).setOperator(_operator);
    }

    function hexGateSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        IHexGate(hexGate).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function hexGateAllocateSeigniorage(uint256 amount) external onlyOperator {
        IHexGate(hexGate).allocateSeigniorage(amount);
    }

    function hexGateGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        IHexGate(hexGate).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
