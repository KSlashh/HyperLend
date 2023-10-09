// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Codec.sol";
import "../libs/access/Ownable.sol";

abstract contract PriceOracle {
    bool public constant isPriceOracle = true;

    function getUnderlyingPrice(bytes32 normalizedTokenAddress) external virtual view returns (uint);
}

contract SimplePriceOracle is PriceOracle, Ownable {

    mapping(address => bool) public providers;
    mapping(bytes32 => uint) public prices;

    modifier onlyProvider() {
        require(providers[msg.sender], "caller is not provider");
        _;
    }

    function addProvider(address _provider) public onlyOwner {
        providers[_provider] = true;
    }

    function removeProvider(address _provider) public onlyOwner {
        providers[_provider] = false;
    }

    function getUnderlyingPrice(bytes32 normalizedTokenAddress) public view override returns (uint) {
        uint price = prices[normalizedTokenAddress];
        require(price != 0, "price not set!");
        return price;
    }

    function setUnderlyingPrice(uint64 branchChainId, address tokenAddress, uint price) public onlyProvider {
        setUnderlyingPrice(Codec.encodeBranchToken(branchChainId, tokenAddress), price);
    }

    function setUnderlyingPrice(bytes32 normalizedTokenAddress, uint price) public onlyProvider {
        prices[normalizedTokenAddress] = price;
    }
}
