// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract CrossChainManager {
    function crossChain(
        uint64 toChainId, 
        bytes calldata toContract, 
        bytes calldata method, 
        bytes calldata txData
    ) external returns (bool) {}
}