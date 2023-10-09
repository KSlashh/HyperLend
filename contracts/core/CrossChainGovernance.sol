// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../interfaces/ICrossChainManager.sol";
import "../libs/utils/Utils.sol";

abstract contract Core {

    // bytes constant BRANCH_RECEIVE_METHOD_BYTES = "0x726563656976654d657373616765"; // receiveMessage

    address managerContractAddress;
    mapping(uint64 => bytes) branchMap;

    modifier onlyManagerContract {
        require(msg.sender == managerContractAddress, "msgSender is not CrossChainManagerContract");
        _;
    }

    modifier onlyBranch(bytes memory fromContractAddr, uint64 fromChainId) {
        require(Utils.equalStorage(branchMap[fromChainId], fromContractAddr), "from contract is not valid branch contract");
        _;
    }

    function sendMessageToBranch(
        uint64 branchChainId,
        bytes memory message
    ) virtual internal {
        require(branchMap[branchChainId].length != 0, "invalid branch chainId");
        require(
            CrossChainManager(managerContractAddress).crossChain(
                branchChainId,
                branchMap[branchChainId],
                abi.encodePacked("receiveMessage"),
                message),
            "CrossChainManager crossChain executed error!"
        );
    }

    function receiveMessage(
        bytes memory argsBs,
        bytes memory fromContractAddr,
        uint64 fromChainId
    ) onlyManagerContract onlyBranch(fromContractAddr, fromChainId) virtual external returns (bool) {
        handleBranchMessage(fromChainId, argsBs);
        return true;
    }

    function handleBranchMessage(uint64 branchChainId, bytes memory message) virtual internal;

}


abstract contract Branch {

    // bytes constant CORE_RECEIVE_METHOD_BYTES = "0x726563656976654d657373616765"; // receiveMessage

    address managerContractAddress;
    bytes coreAddress;
    uint64 coreChainId;

    modifier onlyManagerContract {
        require(msg.sender == managerContractAddress, "msgSender is not CrossChainManagerContract");
        _;
    }

    modifier onlyCore(bytes memory fromContractAddr, uint64 fromChainId) {
        require(coreChainId == fromChainId, "from chain is not core chain");
        require(Utils.equalStorage(coreAddress, fromContractAddr), "from contract is not core contract");
        _;
    }

    function sendMessageToCore(
        bytes memory message
    ) virtual internal {
        require(
            CrossChainManager(managerContractAddress).crossChain(
                coreChainId,
                coreAddress,
                abi.encodePacked("receiveMessage"),
                message),
            "CrossChainManager crossChain executed error!"
        );
    }

    function receiveMessage(
        bytes memory argsBs,
        bytes memory fromContractAddr,
        uint64 fromChainId
    ) onlyManagerContract onlyCore(fromContractAddr, fromChainId) external returns (bool) {
        handleCoreMessage(argsBs);
        return true;
    }

    function handleCoreMessage(bytes memory message) virtual internal;

}