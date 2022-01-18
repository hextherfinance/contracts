// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
 __    __   _______  ___      ___  ____________   __    __   _______   ________
|  |  |  | |   ____| \  \    /  / |____    ____| |  |  |  | |   ____| |   ____  \ 
|  |__|  | |  |___    \  \__/  /       |  |      |  |__|  | |  |___   |  |   /  /
|   __   | |   ___|    |  __  |        |  |      |   __   | |   ___|  |  |  /__/
|  |  |  | |  |____   /  /  \  \       |  |      |  |  |  | |  |____  |  |  \  \ 
|__|  |__| |_______| /__/    \__\      |__|      |__|  |__| |_______| |__|   \__\ 

*/


contract TaxOracle is Ownable {
    using SafeMath for uint256;

    IERC20 public hexther;
    IERC20 public wbnb;
    address public pair;

    constructor(
        address _hexther,
        address _wbnb,
        address _pair
    ) public {
        require(_hexther != address(0), "hexther address cannot be 0");
        require(_wbnb != address(0), "wbnb address cannot be 0");
        require(_pair != address(0), "pair address cannot be 0");
        hexther = IERC20(_hexther);
        wbnb = IERC20(_wbnb);
        pair = _pair;
    }

    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        require(_token == address(hexther), "token needs to be hexther");
        uint256 hextherBalance = hexther.balanceOf(pair);
        uint256 wbnbBalance = wbnb.balanceOf(pair);
        return uint144(hextherBalance.mul(_amountIn).div(wbnbBalance));
    }

    function getHextherBalance() external view returns (uint256) {
	return hexther.balanceOf(pair);
    }

    function getBtcbBalance() external view returns (uint256) {
	return wbnb.balanceOf(pair);
    }

    function getPrice() external view returns (uint256) {
        uint256 hextherBalance = hexther.balanceOf(pair);
        uint256 wbnbBalance = wbnb.balanceOf(pair);
        return hextherBalance.mul(1e18).div(wbnbBalance);
    }

    function setHexther(address _hexther) external onlyOwner {
        require(_hexther != address(0), "hexther address cannot be 0");
        hexther = IERC20(_hexther);
    }

    function setWbnb(address _wbnb) external onlyOwner {
        require(_wbnb != address(0), "wbnb address cannot be 0");
        wbnb = IERC20(_wbnb);
    }

    function setPair(address _pair) external onlyOwner {
        require(_pair != address(0), "pair address cannot be 0");
        pair = _pair;
    }
}