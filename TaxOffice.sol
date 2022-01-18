// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";

/*
 __    __   _______  ___      ___  ____________   __    __   _______   ________
|  |  |  | |   ____| \  \    /  / |____    ____| |  |  |  | |   ____| |   ____  \ 
|  |__|  | |  |___    \  \__/  /       |  |      |  |__|  | |  |___   |  |   /  /
|   __   | |   ___|    |  __  |        |  |      |   __   | |   ___|  |  |  /__/
|  |  |  | |  |____   /  /  \  \       |  |      |  |  |  | |  |____  |  |  \  \ 
|__|  |__| |_______| /__/    \__\      |__|      |__|  |__| |_______| |__|   \__\ 

*/

contract TaxOffice is Operator {
    address public hexther;

    constructor(address _hexther) public {
        require(_hexther != address(0), "hexther address cannot be 0");
        hexther = _hexther;
    }

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(hexther).setTaxTiersTwap(_index, _value);
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(hexther).setTaxTiersRate(_index, _value);
    }

    function enableAutoCalculateTax() public onlyOperator {
        ITaxable(hexther).enableAutoCalculateTax();
    }

    function disableAutoCalculateTax() public onlyOperator {
        ITaxable(hexther).disableAutoCalculateTax();
    }

    function setTaxRate(uint256 _taxRate) public onlyOperator {
        ITaxable(hexther).setTaxRate(_taxRate);
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyOperator {
        ITaxable(hexther).setBurnThreshold(_burnThreshold);
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        ITaxable(hexther).setTaxCollectorAddress(_taxCollectorAddress);
    }

    function excludeAddressFromTax(address _address) external onlyOperator returns (bool) {
        return ITaxable(hexther).excludeAddress(_address);
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return ITaxable(hexther).includeAddress(_address);
    }

    function setTaxableHextherOracle(address _hextherOracle) external onlyOperator {
        ITaxable(hexther).setHextherOracle(_hextherOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(hexther).setTaxOffice(_newTaxOffice);
    }
}
