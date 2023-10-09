// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "../libs/common/ZeroCopySink.sol";
import "../libs/common/ZeroCopySource.sol";
import "../libs/utils/Utils.sol";

library Codec {

    type TAG is bytes1;

    TAG constant MANAGE_DEPOSIT_TAG = TAG.wrap(0x01);
    TAG constant MANAGE_BORROW_TAG = TAG.wrap(0x02);
    TAG constant DEPOSIT_TAG = TAG.wrap(0x03);
    TAG constant WITHDRAW_TAG = TAG.wrap(0x04);
    TAG constant BORROW_TAG = TAG.wrap(0x05);
    TAG constant REPAY_BORROW_TAG = TAG.wrap(0x06);

    function getTag(bytes memory message) pure public returns(TAG) {
        return TAG.wrap(message[0]);
    }

    // return true is tag1 == tag2
    function compareTag(TAG tag1, TAG tag2) pure public returns(bool) {
        return TAG.unwrap(tag1) == TAG.unwrap(tag2);
    }



    function encodeManageDepositMessage(bool isEnable, bool applyToAll, address tokenAddress) pure public returns(bytes memory) {
        bytes memory buff;
        buff = abi.encodePacked(
            MANAGE_DEPOSIT_TAG,
            ZeroCopySink.WriteBool(isEnable),
            ZeroCopySink.WriteBool(applyToAll),
            ZeroCopySink.WriteAddress(tokenAddress)
            );
        return buff;
    }
    function decodeManageDepositMessage(bytes memory rawData) pure public returns(bool isEnable, bool applyToAll, address tokenAddress) {
        require(compareTag(getTag(rawData), MANAGE_DEPOSIT_TAG), "Not manage_deposit message");
        uint off = 1;
        (isEnable, off) = ZeroCopySource.NextBool(rawData, off);
        (applyToAll, off) = ZeroCopySource.NextBool(rawData, off);
        (tokenAddress, off) = ZeroCopySource.NextAddress(rawData, off);
    }



    function encodeManageBorrowMessage(bool isEnable, bool applyToAll, address tokenAddress) pure public returns(bytes memory) {
        bytes memory buff;
        buff = abi.encodePacked(
            MANAGE_BORROW_TAG,
            ZeroCopySink.WriteBool(isEnable),
            ZeroCopySink.WriteBool(applyToAll),
            ZeroCopySink.WriteAddress(tokenAddress)
            );
        return buff;
    }
    function decodeManageBorrowMessage(bytes memory rawData) pure public returns(bool isEnable, bool applyToAll, address tokenAddress) {
        require(compareTag(getTag(rawData), MANAGE_BORROW_TAG), "Not manage_borrow message");
        uint off = 1;
        (isEnable, off) = ZeroCopySource.NextBool(rawData, off);
        (applyToAll, off) = ZeroCopySource.NextBool(rawData, off);
        (tokenAddress, off) = ZeroCopySource.NextAddress(rawData, off);
    }



    function encodeDepositMessage(address userAddress, address token, uint256 amount) pure public returns(bytes memory) {
        bytes memory buff;
        buff = abi.encodePacked(
            DEPOSIT_TAG,
            ZeroCopySink.WriteAddress(userAddress),
            ZeroCopySink.WriteAddress(token),
            ZeroCopySink.WriteUint255(amount)
            );
        return buff;
    }
    function decodeDepositMessage(bytes memory rawData) pure public returns(address userAddress, address token, uint256 amount) {
        require(compareTag(getTag(rawData), DEPOSIT_TAG), "Not deposit message");
        uint256 off = 1;
        (userAddress, off) = ZeroCopySource.NextAddress(rawData, off);
        (token, off) = ZeroCopySource.NextAddress(rawData, off);
        (amount, off) = ZeroCopySource.NextUint255(rawData, off);
    }



    function encodeWithdrawMessage(address userAddress, address token, uint256 amount) pure public returns(bytes memory) {
        bytes memory buff;
        buff = abi.encodePacked(
            WITHDRAW_TAG,
            ZeroCopySink.WriteAddress(userAddress),
            ZeroCopySink.WriteAddress(token),
            ZeroCopySink.WriteUint255(amount)
            );
        return buff;
    }
    function decodeWithdrawMessage(bytes memory rawData) pure public returns(address userAddress, address token, uint256 amount) {
        require(compareTag(getTag(rawData), WITHDRAW_TAG), "Not withdraw message");
        uint256 off = 1;
        (userAddress, off) = ZeroCopySource.NextAddress(rawData, off);
        (token, off) = ZeroCopySource.NextAddress(rawData, off);
        (amount, off) = ZeroCopySource.NextUint255(rawData, off);
    }



    function encodeBorrowMessage(address userAddress, address token, uint256 amount) pure public returns(bytes memory) {
        bytes memory buff;
        buff = abi.encodePacked(
            BORROW_TAG,
            ZeroCopySink.WriteAddress(userAddress),
            ZeroCopySink.WriteAddress(token),
            ZeroCopySink.WriteUint255(amount)
            );
        return buff;
    }
    function decodeBorrowMessage(bytes memory rawData) pure public returns(address userAddress, address token, uint256 amount) {
        require(compareTag(getTag(rawData), BORROW_TAG), "Not borrow message");
        uint256 off = 1;
        (userAddress, off) = ZeroCopySource.NextAddress(rawData, off);
        (token, off) = ZeroCopySource.NextAddress(rawData, off);
        (amount, off) = ZeroCopySource.NextUint255(rawData, off);
    }



    function encodeRepayBorrowMessage(address userAddress, address token, uint256 amount) pure public returns(bytes memory) {
        bytes memory buff;
        buff = abi.encodePacked(
            REPAY_BORROW_TAG,
            ZeroCopySink.WriteAddress(userAddress),
            ZeroCopySink.WriteAddress(token),
            ZeroCopySink.WriteUint255(amount)
            );
        return buff;
    }
    function decodeRepayBorrowMessage(bytes memory rawData) pure public returns(address userAddress, address token, uint256 amount) {
        require(compareTag(getTag(rawData), REPAY_BORROW_TAG), "Not repay borrow message");
        uint256 off = 1;
        (userAddress, off) = ZeroCopySource.NextAddress(rawData, off);
        (token, off) = ZeroCopySource.NextAddress(rawData, off);
        (amount, off) = ZeroCopySource.NextUint255(rawData, off);
    }


    function encodeBranchToken(uint64 branchChainId, address tokenAddress) pure public returns(bytes32) {
        bytes32 res;
        assembly {
            res := add(tokenAddress, shl(224, branchChainId))
        }
        return res;
    }
    function decodeBranchToken(bytes32 normalizedTokenAddress) pure public returns(uint64 branchChainId, address tokenAddress) {
        assembly {
            branchChainId := shr(224, normalizedTokenAddress)
            tokenAddress := shr(64, shl(64, normalizedTokenAddress))
        }
    }
}