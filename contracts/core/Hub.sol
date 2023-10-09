// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "./Exponential.sol";
import "./PriceOracle.sol";
import "./InterestRateModel.sol";
import "./CrossChainGovernance.sol";
import "../libs/access/Ownable.sol";
import "../libs/utils/math/SafeMath.sol";

contract Storage {
    struct Market {
        bool isListed;
        uint collateralFactorMantissa;
    }
    struct BorrowSnapshot {
        uint principal;
        uint interestIndex;
    }
    struct ZTokenSnapShot {
        uint balance;
        uint accrualBlockNumber;
        uint borrowIndex;
        uint totalBorrows;
        uint totalReserves;
        uint totalSupply;
    }

    PriceOracle public oracle;
    InterestRateModel public interestRateModel;

    mapping(address => bytes32[]) public accountAssets;
    mapping(bytes32 => mapping(address => uint)) public accountTokens;
    mapping(bytes32 => mapping(address => BorrowSnapshot)) public accountBorrows;

    uint internal constant borrowRateMaxMantissa = 0.0005e16; 
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    uint public reserveFactorMantissa = 0.05e18; // 5%
    uint internal initialExchangeRateMantissa = 1e18;
    uint public closeFactorMantissa = 0.5e18; // 50%
    uint public liquidationIncentiveMantissa = 1.08e18; // 108%
    bytes32[] public allMarkets;
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => ZTokenSnapShot) public zTokenSnapshots;

    bool public mintGuardianPausedAll;
    bool public borrowGuardianPausedAll;
    bool public seizeGuardianPausedAll;
    mapping(uint64 => bool) public mintGuardianPausedChain;
    mapping(uint64 => bool) public borrowGuardianPausedChain;
    mapping(bytes32 => bool) public mintGuardianPausedZToken;
    mapping(bytes32 => bool) public borrowGuardianPausedZToken;

    uint64 internal constant SENTINEL_BRANCH = 0xffffffffffffffff;
    mapping(uint64 => uint64) internal branchs;
    uint256 internal branchCount;
}

contract Events {
    event BindBranchEvent(uint64 branchChainId, bytes branchAddress);

    event AccrueInterest(bytes32 ZToken, uint cashPrior, uint interestAccumulated, uint borrowIndex, uint totalBorrows);
    event Mint(bytes32 ZToken, address minter, uint mintAmount, uint mintTokens);
    event Redeem(bytes32 ZToken, address redeemer, uint redeemAmount, uint redeemTokens);
    event RedeemFailed(bytes32 ZToken, address redeemer, uint redeemAmount);
    event Borrow(bytes32 ZToken, address borrower, uint borrowAmount, uint accountBorrows, uint totalBorrows);
    event BorrowFailed(bytes32 ZToken, address borrower, uint borrowAmount);
    event RepayBorrow(bytes32 ZToken, address borrower, uint repayAmount, uint accountBorrows, uint totalBorrows);
    event LiquidateBorrow(bytes32 zTokenBorrowed, bytes32 zTokenCollateral, address liquidator, address borrower, uint repayTokens, uint seizeTokens);
    event ReservesAdded(bytes ZToken, address benefactor, uint addAmount, uint newTotalReserves);
    event ReservesReduced(bytes ZToken, address admin, uint reduceAmount, uint newTotalReserves);

    event MarketListed(bytes32 ZToken);
    event NewCollateralFactor(bytes32 ZToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);
    event NewMarketInterestRateModel(InterestRateModel oldInterestRateModel, InterestRateModel newInterestRateModel);

    event ActionPaused(string action, bool pauseState);
    event ActionPaused(bytes32 ZToken, string action, bool pauseState);
    event ActionPaused(uint64 branchChainId, string action, bool pauseState);

    event Debug(uint num, CarefulMath.MathError mathErr);
}

contract Hub is Core, Exponential, Ownable, Storage, Events {
    using SafeMath for uint;

    constructor(address _managerContractAddress) {
        managerContractAddress = _managerContractAddress;
        branchs[SENTINEL_BRANCH] = SENTINEL_BRANCH;
    }

    // User functions
    function redeem(uint64 branchChainId, address token, uint redeemAmount) external {
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        accrueInterest(normalizedToken);
        bool success = redeemInternal(normalizedToken, msg.sender, redeemAmount);
        require(success, "redeem failed");
    }
    function redeemAll(uint64 branchChainId, address token) external {
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        accrueInterest(normalizedToken);

        MathError mathErr;
        uint exchangeRateMantissa;
        uint redeemAmount; 
        uint redeemTokens = accountTokens[normalizedToken][msg.sender];
        (mathErr, exchangeRateMantissa) = exchangeRateStoredInternal(normalizedToken);
        require(mathErr == MathError.NO_ERROR, "redeem failed -0");
        (mathErr, redeemAmount) = mulScalarTruncate(Exp({mantissa: exchangeRateMantissa}), redeemTokens);
        require(mathErr == MathError.NO_ERROR, "redeem failed -1");

        bool success = redeemInternal(normalizedToken, msg.sender, redeemAmount);
        require(success, "redeem failed");
    }
    function borrow(uint64 branchChainId, address token, uint borrowAmount) external {
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        accrueInterest(normalizedToken);
        bool success = borrowInternal(normalizedToken, msg.sender, borrowAmount);
        require(success, "borrow failed!");
    }
    function liquidateBorrow(address borrower, bytes32 zTokenBorrowed, bytes32 zTokenCollateral, uint repayTokens) external {
        // check
        address liquidator = msg.sender;
        require(markets[zTokenBorrowed].isListed && markets[zTokenCollateral].isListed, "not lisited");
        require(msg.sender != borrower, "liquidator is borrower");
        require(repayTokens != 0, "repay amount is zero");
        require(accountTokens[zTokenBorrowed][liquidator] >= repayTokens, "liquidator do not have enough balance");
        accrueInterest(zTokenBorrowed);
        accrueInterest(zTokenCollateral);
        uint repayAmount;
        MathError mathErr;
        {
        uint exchangeRateMantissa;
        (mathErr, exchangeRateMantissa) = exchangeRateStoredInternal(zTokenBorrowed);
        require(mathErr == MathError.NO_ERROR, "math error -0");
        (mathErr, repayAmount) = mulScalarTruncate(Exp({mantissa: exchangeRateMantissa}), repayTokens);
        require(mathErr == MathError.NO_ERROR, "math error -1");
        (, uint shortfall) = getAccountLiquidityInternal(borrower);
        require(shortfall != 0, "no shortfall");
        uint borrowBalance;
        (mathErr, borrowBalance) = borrowBalanceStoredInternal(zTokenBorrowed, borrower);
        uint maxClose;
        (mathErr, maxClose) = mulScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        require(mathErr == MathError.NO_ERROR, "calc maxClose error");
        require(repayAmount <= maxClose, "too much repay"); 
        }
        uint seizeTokens = liquidateCalculateSeizeTokens(zTokenBorrowed, zTokenCollateral, repayAmount);
        require(accountTokens[zTokenCollateral][borrower] >= seizeTokens, "liquidate seize too much");

        // repay
        uint liquidatorTokensBorrowedNew;
        (mathErr, liquidatorTokensBorrowedNew) = subUInt(accountTokens[zTokenBorrowed][liquidator], repayTokens);
        require(mathErr == MathError.NO_ERROR, "math error -2");
        (bool success,) = repayBorrowInternal(zTokenBorrowed, borrower, repayAmount);
        require(success, "repay borrow failed");

        // seize
        uint borrowerTokensCollateralNew;
        uint liquidatorTokensCollateralNew;
        (mathErr, borrowerTokensCollateralNew) = subUInt(accountTokens[zTokenCollateral][borrower], seizeTokens);
        require(mathErr == MathError.NO_ERROR, "math error -3");
        (mathErr, liquidatorTokensCollateralNew) = addUInt(accountTokens[zTokenCollateral][liquidator], seizeTokens);
        require(mathErr == MathError.NO_ERROR, "math error -4");

        // update
        tryAddAccountAsset(zTokenCollateral, liquidator);
        accountTokens[zTokenBorrowed][liquidator] = liquidatorTokensBorrowedNew;
        accountTokens[zTokenCollateral][liquidator] = liquidatorTokensCollateralNew;
        accountTokens[zTokenCollateral][borrower] = borrowerTokensCollateralNew;

        emit LiquidateBorrow(zTokenBorrowed, zTokenCollateral, liquidator, borrower, repayTokens, seizeTokens);
    }

    // Market Management
    function supportToken(uint64 branchChainId, address token) onlyOwner public {
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        require(!markets[normalizedToken].isListed, "already listed");

        allMarkets.push(normalizedToken);
        markets[normalizedToken].isListed = true;
        updateAccrualBlockNumber(normalizedToken, block.number);
        updateBorrowIndex(normalizedToken, mantissaOne);
        sendManageDepositToBranch(branchChainId, true, false, token);
        sendManageBorrowToBranch(branchChainId, true, false, token);

        emit MarketListed(normalizedToken);
    }
    function setCollateralFactor(uint64 branchChainId, address token, uint newCollateralFactorMantissa) onlyOwner public {
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        require(markets[normalizedToken].isListed, "not listed");

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        require(!lessThanExp(highLimit, newCollateralFactorExp), "invalid collateral factor");
        require(newCollateralFactorMantissa == 0 || oracle.getUnderlyingPrice(normalizedToken) != 0, "set collateral factor without price");

        uint oldCollateralFactorMantissa = markets[normalizedToken].collateralFactorMantissa;
        markets[normalizedToken].collateralFactorMantissa = newCollateralFactorMantissa;

        emit NewCollateralFactor(normalizedToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);
    }
    function setPriceOracle(PriceOracle newOracle) onlyOwner public {
        PriceOracle oldOracle = oracle;
        oracle = newOracle;

        emit NewPriceOracle(oldOracle, newOracle);
    }
    function setInterestRateModel(InterestRateModel newInterestRateModel) onlyOwner public {
        InterestRateModel oldInterestRateModel = interestRateModel;
        interestRateModel = newInterestRateModel;

        emit NewMarketInterestRateModel(oldInterestRateModel, newInterestRateModel);
    }
    function setZTokenBorrowPaused(uint64 branchChainId, address token, bool state) onlyOwner public {
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        if (borrowGuardianPausedZToken[normalizedToken] != state) {
            borrowGuardianPausedZToken[normalizedToken] = state;
            sendManageBorrowToBranch(branchChainId, !state, false, token);
            emit ActionPaused(normalizedToken, "Borrow,token", state);
        } else {
            revert("nothing will change");
        }
    }
    function setZTokenMintPaused(uint64 branchChainId, address token, bool state) onlyOwner public {
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        if (mintGuardianPausedZToken[normalizedToken] != state) {
            mintGuardianPausedZToken[normalizedToken] = state;
            sendManageDepositToBranch(branchChainId, !state, false, token);
            emit ActionPaused(normalizedToken, "Deposit,token", state);
        } else {
            revert("nothing will change");
        }
    }
    function setChainBorrowPaused(uint64 branchChainId, bool state) onlyOwner public {
        if (borrowGuardianPausedChain[branchChainId] != state) {
            borrowGuardianPausedChain[branchChainId] = state;
            sendManageBorrowToBranch(branchChainId, !state, true, 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
            emit ActionPaused(branchChainId, "Borrow,chain", state);
        } else {
            revert("nothing will change");
        }
    }
    function setChainMintPaused(uint64 branchChainId, bool state) onlyOwner public {
        if (mintGuardianPausedChain[branchChainId] != state) {
            mintGuardianPausedChain[branchChainId] = state;
            sendManageDepositToBranch(branchChainId, !state, true, 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF);
            emit ActionPaused(branchChainId, "Deposit,chain", state);
        } else {
            revert("nothing will change");
        }
    }
    function setBorrowPaused(bool state) onlyOwner public {
        require(borrowGuardianPausedAll != state, "nothing will change");
        borrowGuardianPausedAll = state;
        emit ActionPaused("Borrow,all", state);
    }
    function setMintPaused(bool state) onlyOwner public {
        require(mintGuardianPausedAll != state, "nothing will change");
        mintGuardianPausedAll = state;
        emit ActionPaused("Deposit,all", state);
    }
    function setSeizePaused(bool state) onlyOwner public {
        require(seizeGuardianPausedAll != state, "nothing will change");
        seizeGuardianPausedAll = state;
        emit ActionPaused("Liquidate,all", state);
    }

    function sendManageBorrowToBranch(uint64 toChainId, bool isEnable, bool applyToAll, address tokenAddress) internal {
        bytes memory data = Codec.encodeManageBorrowMessage(isEnable, applyToAll, tokenAddress);
        sendMessageToBranch(toChainId, data);
    }
    function sendManageDepositToBranch(uint64 toChainId, bool isEnable, bool applyToAll, address tokenAddress) internal {
        bytes memory data = Codec.encodeManageDepositMessage(isEnable, applyToAll, tokenAddress);
        sendMessageToBranch(toChainId, data);
    }
    
    // Branch Management
    function bindBranch(uint64 branchChainId, bytes memory branchAddress) onlyOwner public {
        branchMap[branchChainId] = branchAddress;
        if (branchAddress.length == 0) {
            removeBranch(branchChainId);
        } else {
            addBranch(branchChainId);
        }
        emit BindBranchEvent(branchChainId, branchAddress); 
    }
    function bindBranchBatch(uint64[] memory branchChainIds, bytes[] memory branchAddrs) onlyOwner public {
        require(branchChainIds.length == branchAddrs.length, "input lists length do not match");
        for (uint i = 0; i < branchChainIds.length; i++) {
            uint64 branchChainId = branchChainIds[i];
            bytes memory branchAddress = branchAddrs[i];
            branchMap[branchChainId] = branchAddress;
            if (branchAddress.length == 0) {
                removeBranch(branchChainId);
            } else {
                addBranch(branchChainId);
            }
            emit BindBranchEvent(branchChainId, branchAddress); 
        }
    }
    function addBranch(uint64 newBranchChainId) internal {
        require(newBranchChainId != SENTINEL_BRANCH, "Invalid branch chainId provided");
        if (branchs[newBranchChainId] != 0) { return; } // No duplicate branch chainId
        branchs[newBranchChainId] = branchs[SENTINEL_BRANCH];
        branchs[SENTINEL_BRANCH] = newBranchChainId;
        branchCount++;
    }
    function removeBranch(uint64 branchChainId) internal {
        require(branchChainId != SENTINEL_BRANCH, "Invalid branch chainId provided");
        if (branchs[branchChainId] == 0) { return; }
        uint64 prevBranch = branchs[SENTINEL_BRANCH];
        for (;branchs[prevBranch] != branchChainId;) {
            prevBranch = branchs[prevBranch];
        }
        branchs[prevBranch] = branchs[branchChainId];
        branchs[branchChainId] = 0;
        branchCount--;
    }
    function getBranchs() public view returns (uint64[] memory chainIdArray) {
        uint64[] memory arrayChainId = new uint64[](branchCount);

        // populate return array
        uint256 index = 0;
        uint64 currentBranch = branchs[SENTINEL_BRANCH];
        while (currentBranch != SENTINEL_BRANCH) {
            arrayChainId[index] = currentBranch;
            currentBranch = branchs[currentBranch];
            index++;
        }
        return arrayChainId;
    }

    // Handler 
    function handleBranchMessage(uint64 branchChainId, bytes memory message) override internal {
        Codec.TAG tag = Codec.getTag(message);
        if (Codec.compareTag(tag, Codec.DEPOSIT_TAG)) {
            handleDepositMessage(branchChainId, message);
        } else if (Codec.compareTag(tag, Codec.WITHDRAW_TAG)) {
            handleWithdrawMessage(branchChainId, message);
        } else if (Codec.compareTag(tag, Codec.BORROW_TAG)) {
            handleBorrowMessage(branchChainId, message);
        } else if (Codec.compareTag(tag, Codec.REPAY_BORROW_TAG)) {
            handleRepayBorrowMessage(branchChainId, message);
        } else {
            revert("Unknown tag");
        }
    }
    function handleDepositMessage(uint64 branchChainId, bytes memory message) internal {
        (address minter, address token, uint256 amount) = Codec.decodeDepositMessage(message);
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        accrueInterest(normalizedToken);
        bool success = mintInternal(normalizedToken, minter, amount);
        if (!success) {
            sendWithdrawToBranch(normalizedToken, minter, amount);
        }
    }
    function handleWithdrawMessage(uint64 branchChainId, bytes memory message) internal {
        (address redeemer, address token, uint256 amount) = Codec.decodeWithdrawMessage(message);
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        accrueInterest(normalizedToken);
        bool success = redeemInternal(normalizedToken, redeemer, amount);
        if (!success) {
            emit RedeemFailed(normalizedToken, redeemer, amount);
        }
    }
    function handleBorrowMessage(uint64 branchChainId, bytes memory message) internal {
        (address borrower, address token, uint256 amount) = Codec.decodeBorrowMessage(message);
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        accrueInterest(normalizedToken);
        bool success = borrowInternal(normalizedToken, borrower, amount);
        if (!success) {
            emit BorrowFailed(normalizedToken, borrower, amount);
        }
    }
    function handleRepayBorrowMessage(uint64 branchChainId, bytes memory message) internal {
        (address borrower, address token, uint256 amount) = Codec.decodeRepayBorrowMessage(message);
        bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
        accrueInterest(normalizedToken);
        (bool success, uint surplus) = repayBorrowInternal(normalizedToken, borrower, amount);
        if (!success) {
            sendWithdrawToBranch(normalizedToken, borrower, amount);
            return;
        }
        if (surplus != 0) {
            success = mintInternal(normalizedToken, borrower, surplus);
            if (!success) {
                sendWithdrawToBranch(normalizedToken, borrower, surplus);
            }
        }
    }

    function sendWithdrawToBranch(uint64 toChainId, address toAddress, address tokenAddress, uint amount) internal {
        bytes memory withdrawData = Codec.encodeWithdrawMessage(toAddress, tokenAddress, amount);
        sendMessageToBranch(toChainId, withdrawData);
    }
    function sendWithdrawToBranch(bytes32 normalizedToken, address toAddress, uint amount) internal {
        (uint64 toChainId, address tokenAddress) = Codec.decodeBranchToken(normalizedToken);
        bytes memory withdrawData = Codec.encodeWithdrawMessage(toAddress, tokenAddress, amount);
        sendMessageToBranch(toChainId, withdrawData);
    }

    // Internal functions
    function accrueInterest(bytes32 normalizedToken) public {
        uint currentBlockNumber = block.number;
        uint accrualBlockNumberPrior = zTokenSnapshots[normalizedToken].accrualBlockNumber;
        (MathError mathErr, uint blockDelta) = subUInt(currentBlockNumber, accrualBlockNumberPrior);
        require(mathErr == MathError.NO_ERROR, "could not calculate block delta");
        if (blockDelta == 0) {
            return;
        }

        uint cashPrior = totalCash(normalizedToken);
        uint borrowsPrior = totalBorrows(normalizedToken);
        uint reservesPrior = totalReserves(normalizedToken);
        uint borrowIndexPrior = borrowIndex(normalizedToken);
        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "borrow rate is absurdly high");

        Exp memory simpleInterestFactor;
        uint interestAccumulated;
        uint totalBorrowsNew;
        uint totalReservesNew;
        uint borrowIndexNew;

        (mathErr, simpleInterestFactor) = mulScalar(Exp({mantissa: borrowRateMantissa}), blockDelta);
        require(mathErr == MathError.NO_ERROR, "ACCRUE_INTEREST_SIMPLE_INTEREST_FACTOR_CALCULATION_FAILED");

        (mathErr, interestAccumulated) = mulScalarTruncate(simpleInterestFactor, borrowsPrior);
        require(mathErr == MathError.NO_ERROR, "ACCRUE_INTEREST_ACCUMULATED_INTEREST_CALCULATION_FAILED");

        (mathErr, totalBorrowsNew) = addUInt(interestAccumulated, borrowsPrior);
        require(mathErr == MathError.NO_ERROR, "ACCRUE_INTEREST_NEW_TOTAL_BORROWS_CALCULATION_FAILED");

        (mathErr, totalReservesNew) = mulScalarTruncateAddUInt(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
        require(mathErr == MathError.NO_ERROR, "ACCRUE_INTEREST_NEW_TOTAL_RESERVES_CALCULATION_FAILED");

        (mathErr, borrowIndexNew) = mulScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);
        require(mathErr == MathError.NO_ERROR, "ACCRUE_INTEREST_NEW_BORROW_INDEX_CALCULATION_FAILED");

        updateAccrualBlockNumber(normalizedToken, currentBlockNumber);
        updateBorrowIndex(normalizedToken, borrowIndexNew);
        updateTotalBorrows(normalizedToken, totalBorrowsNew);
        updateTotalReserves(normalizedToken, totalReservesNew);

        emit AccrueInterest(normalizedToken, cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);
    }

    function mintInternal(bytes32 normalizedToken, address minter, uint amount) internal returns (bool success) {
        if (!markets[normalizedToken].isListed) { // token not listed
            emit Debug(1, MathError.NO_ERROR);
            return false;
        } 

        (uint64 branchChainId,) = Codec.decodeBranchToken(normalizedToken);
        if (mintGuardianPausedAll || mintGuardianPausedChain[branchChainId] || mintGuardianPausedZToken[normalizedToken]) { // Depsoit is paused
            emit Debug(2, MathError.NO_ERROR);
            return false;
        }

        tryAddAccountAsset(normalizedToken, minter);

        MathError mathErr;
        uint exchangeRateMantissa;
        uint mintTokens;
        uint actualMintAmount;

        (mathErr, exchangeRateMantissa) = exchangeRateStoredInternal(normalizedToken);
        if (mathErr != MathError.NO_ERROR) { // MINT_EXCHANGE_RATE_READ_FAILED
            emit Debug(3, mathErr);
            return false;
        }

        actualMintAmount = amount;

        (mathErr, mintTokens) = divScalarByExpTruncate(actualMintAmount, Exp({mantissa: exchangeRateMantissa}));
        if (mathErr != MathError.NO_ERROR) { 
            emit Debug(4, mathErr);
            return false;
        }

        updateCash(normalizedToken, totalCash(normalizedToken) + amount);
        updateTotalSupply(normalizedToken, totalSupply(normalizedToken) + mintTokens);
        accountTokens[normalizedToken][minter] = accountTokens[normalizedToken][minter] + mintTokens;

        emit Mint(normalizedToken, minter, actualMintAmount, mintTokens);

        return true;
    }

    function redeemInternal(bytes32 normalizedToken, address redeemer, uint redeemAmount) internal returns (bool success) {
        if (!markets[normalizedToken].isListed) {
            emit Debug(7, MathError.NO_ERROR);
            return false;
        }

        MathError mathErr;
        uint exchangeRateMantissa;
        uint redeemTokens;
        uint accountTokensNew;

        (mathErr, exchangeRateMantissa) = exchangeRateStoredInternal(normalizedToken);
        if (mathErr != MathError.NO_ERROR) {
            emit Debug(9, mathErr);
            return false;
        }

        (mathErr, redeemTokens) = divScalarByExpTruncate(redeemAmount, Exp({mantissa: exchangeRateMantissa}));
        if (mathErr != MathError.NO_ERROR) {
            emit Debug(10, mathErr);
            return false;
        }
        
        (, uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, normalizedToken, redeemTokens, 0);
        if (shortfall > 0) {
            emit Debug(11, mathErr);
            return false;
        }

        (mathErr, accountTokensNew) = subUInt(accountTokens[normalizedToken][redeemer], redeemTokens);
        if (mathErr != MathError.NO_ERROR) {
            emit Debug(13, mathErr);
            return false;
        }

        if (totalCash(normalizedToken) < redeemAmount) {
            emit Debug(14, MathError.NO_ERROR);
            return false;
        }

        sendWithdrawToBranch(normalizedToken, redeemer, redeemAmount);

        updateCash(normalizedToken, totalCash(normalizedToken) - redeemAmount);
        updateTotalSupply(normalizedToken, totalSupply(normalizedToken) - redeemTokens);
        accountTokens[normalizedToken][redeemer] = accountTokensNew;

        emit Redeem(normalizedToken, redeemer, redeemAmount, redeemTokens);

        return true;
    }

    function borrowInternal(bytes32 normalizedToken, address borrower, uint borrowAmount) internal returns (bool success) {
        if (!markets[normalizedToken].isListed) {
            emit Debug(15, MathError.NO_ERROR);
            return false;
        }

        if (totalCash(normalizedToken) < borrowAmount) {
            emit Debug(16, MathError.NO_ERROR);
            return false;
        }

        tryAddAccountAsset(normalizedToken, borrower);
        
        (uint64 branchChainId,) = Codec.decodeBranchToken(normalizedToken);
        if (borrowGuardianPausedAll || borrowGuardianPausedChain[branchChainId] || borrowGuardianPausedZToken[normalizedToken]) { // Borrow is paused
            emit Debug(17, MathError.NO_ERROR);
            return false;
        }
        
        if (oracle.getUnderlyingPrice(normalizedToken) == 0) {
            emit Debug(18, MathError.NO_ERROR);
            return false;
        }

        (, uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, normalizedToken, 0, borrowAmount);
        if (shortfall > 0) {
            emit Debug(19, MathError.NO_ERROR);
            return false;
        }

        MathError mathErr;
        uint accountBorrowsPrior;

        if (totalCash(normalizedToken) < borrowAmount) {
            emit Debug(20, MathError.NO_ERROR);
            return false;
        }

        (mathErr, accountBorrowsPrior) = borrowBalanceStoredInternal(normalizedToken, borrower);
        if (mathErr != MathError.NO_ERROR) {
            emit Debug(21, mathErr);
            return false;
        }
        
        updateCash(normalizedToken, totalCash(normalizedToken) - borrowAmount);
        accountBorrows[normalizedToken][borrower].principal = accountBorrowsPrior + borrowAmount;
        accountBorrows[normalizedToken][borrower].interestIndex = borrowIndex(normalizedToken);
        updateTotalBorrows(normalizedToken, totalBorrows(normalizedToken) + borrowAmount);

        sendWithdrawToBranch(normalizedToken, borrower, borrowAmount);

        emit Borrow(normalizedToken, borrower, borrowAmount, accountBorrowsPrior + borrowAmount, totalBorrows(normalizedToken));

        return true;
    }

    function repayBorrowInternal(bytes32 normalizedToken, address borrower, uint repayAmount) internal returns (bool success, uint surplus) {
        if (!markets[normalizedToken].isListed) {
            return (false, repayAmount);
        }
        
        MathError mathErr;
        uint accountBorrowsPrior;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
        uint actualRepayAmount;

        (mathErr, accountBorrowsPrior) = borrowBalanceStoredInternal(normalizedToken, borrower);
        if (mathErr != MathError.NO_ERROR) {
            return (false, repayAmount);
        }

        if (repayAmount > accountBorrowsPrior) {
            actualRepayAmount = accountBorrowsPrior;
            surplus = repayAmount - actualRepayAmount;
        } else {
            actualRepayAmount = repayAmount;
            surplus = 0;
        }

        (mathErr, accountBorrowsNew) = subUInt(accountBorrowsPrior, actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (false, repayAmount);
        }

        (mathErr, totalBorrowsNew) = subUInt(totalBorrows(normalizedToken), actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (false, repayAmount);
        }

        updateCash(normalizedToken, totalCash(normalizedToken) + repayAmount);
        accountBorrows[normalizedToken][borrower].principal = accountBorrowsNew;
        accountBorrows[normalizedToken][borrower].interestIndex = borrowIndex(normalizedToken);
        updateTotalBorrows(normalizedToken, totalBorrowsNew);

        emit RepayBorrow(normalizedToken, borrower, actualRepayAmount, accountBorrowsNew, totalBorrowsNew);

        return (true, surplus);
    }

    function exchangeRateStoredInternal(bytes32 normalizedToken) internal view returns (MathError, uint exchangeRateMantissa) {
        uint _totalSupply = totalSupply(normalizedToken);
        if (_totalSupply == 0) {
            return (MathError.NO_ERROR, initialExchangeRateMantissa);
        } else {
            uint cashPlusBorrowsMinusReserves;
            Exp memory exchangeRate;
            MathError mathErr;

            (mathErr, cashPlusBorrowsMinusReserves) = addThenSubUInt(totalCash(normalizedToken), totalBorrows(normalizedToken), totalReserves(normalizedToken));
            if (mathErr != MathError.NO_ERROR) {
                return (mathErr, 0);
            }

            (mathErr, exchangeRate) = getExp(cashPlusBorrowsMinusReserves, _totalSupply);
            if (mathErr != MathError.NO_ERROR) {
                return (mathErr, 0);
            }

            return (MathError.NO_ERROR, exchangeRate.mantissa);
        }
    }

    function borrowBalanceStoredInternal(bytes32 normalizedToken, address account) internal view returns (MathError, uint borrowBalance) {
        MathError mathErr;
        uint principalTimesIndex;
        uint result;

        BorrowSnapshot storage borrowSnapshot = accountBorrows[normalizedToken][account];

        if (borrowSnapshot.principal == 0) {
            return (MathError.NO_ERROR, 0);
        }

        (mathErr, principalTimesIndex) = mulUInt(borrowSnapshot.principal, borrowIndex(normalizedToken));
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }

        (mathErr, result) = divUInt(principalTimesIndex, borrowSnapshot.interestIndex);
        if (mathErr != MathError.NO_ERROR) {
            return (mathErr, 0);
        }

        return (MathError.NO_ERROR, result);
    }

    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint zTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }
    function getHypotheticalAccountLiquidityInternal(
        address account,
        bytes32 zTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (uint excess, uint shortfall) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        MathError mErr;

        // For each asset the account is in
        bytes32[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            bytes32 asset = assets[i];

            vars.zTokenBalance = accountTokens[asset][account];
            (mErr, vars.borrowBalance) = borrowBalanceStoredInternal(asset, account);
            require(mErr == MathError.NO_ERROR, "fail to calc borrow balance");
            (mErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal(asset);
            require(mErr == MathError.NO_ERROR, "fail to calc exchangeRateStoredInternal");

            vars.collateralFactor = Exp({mantissa: markets[asset].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            require(vars.oraclePriceMantissa != 0, "get price failed");
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            (mErr, vars.tokensToDenom) = mulExp3(vars.collateralFactor, vars.exchangeRate, vars.oraclePrice);
            require(mErr == MathError.NO_ERROR, "math error _1");

            // sumCollateral += tokensToDenom * zTokenBalance
            (mErr, vars.sumCollateral) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.zTokenBalance, vars.sumCollateral);
            require(mErr == MathError.NO_ERROR, "math error _2");

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            require(mErr == MathError.NO_ERROR, "math error _3");

            // Calculate effects of interacting with cTokenModify
            if (asset == zTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);
                require(mErr == MathError.NO_ERROR, "math error _4");

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
                require(mErr == MathError.NO_ERROR, "math error _5");
            }
        }

        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }
    function getAccountLiquidityInternal(address account) internal view returns (uint excess, uint shortfall) {
        return getHypotheticalAccountLiquidityInternal(account, bytes32(0), 0, 0);
    }

    function liquidateCalculateSeizeTokens(bytes32 zTokenBorrowed, bytes32 zTokenCollateral, uint actualRepayAmount) public view returns (uint seizeTokens) {
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(zTokenBorrowed);
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(zTokenCollateral);
        require(priceBorrowedMantissa != 0 && priceCollateralMantissa != 0, "price error");

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;
        (mathErr, exchangeRateMantissa) = exchangeRateStoredInternal(zTokenCollateral); 
        require(mathErr == MathError.NO_ERROR, "math error -0");

        (mathErr, numerator) = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        require(mathErr == MathError.NO_ERROR, "math error -1");

        (mathErr, denominator) = mulExp(priceCollateralMantissa, exchangeRateMantissa);
        require(mathErr == MathError.NO_ERROR, "math error -2");

        (mathErr, ratio) = divExp(numerator, denominator);
        require(mathErr == MathError.NO_ERROR, "math error -3");

        (mathErr, seizeTokens) = mulScalarTruncate(ratio, actualRepayAmount);
        require(mathErr == MathError.NO_ERROR, "math error -4");

        return seizeTokens;
    }

    function tryAddAccountAsset(bytes32 zToken, address account) internal {
        bytes32[] memory userAssetList = accountAssets[account];
        uint len = userAssetList.length;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == zToken) {
                return;
            }
        }
        accountAssets[account].push(zToken);
    }

    function updateCash(bytes32 normalizedToken, uint _balance) internal {
        zTokenSnapshots[normalizedToken].balance = _balance;
    }
    function updateAccrualBlockNumber(bytes32 normalizedToken, uint _accrualBlockNumber) internal {
        zTokenSnapshots[normalizedToken].accrualBlockNumber = _accrualBlockNumber;
    }
    function updateBorrowIndex(bytes32 normalizedToken, uint _borrowIndex) internal {
        zTokenSnapshots[normalizedToken].borrowIndex = _borrowIndex;
    }
    function updateTotalBorrows(bytes32 normalizedToken, uint _totalBorrows) internal {
        zTokenSnapshots[normalizedToken].totalBorrows = _totalBorrows;
    }
    function updateTotalReserves(bytes32 normalizedToken, uint _totalReserves) internal {
        zTokenSnapshots[normalizedToken].totalReserves = _totalReserves;
    }
    function updateTotalSupply(bytes32 normalizedToken, uint _totalSupply) internal {
        zTokenSnapshots[normalizedToken].totalSupply = _totalSupply;
    }

    // getter functions
    function totalCash(bytes32 normalizedToken) public view returns(uint) {
        return zTokenSnapshots[normalizedToken].balance;
    }
    function accrualBlockNumber(bytes32 normalizedToken) public view returns(uint) {
        return zTokenSnapshots[normalizedToken].accrualBlockNumber;
    }
    function borrowIndex(bytes32 normalizedToken) public view returns(uint) {
        return zTokenSnapshots[normalizedToken].borrowIndex;
    }
    function totalBorrows(bytes32 normalizedToken) public view returns(uint) {
        return zTokenSnapshots[normalizedToken].totalBorrows;
    }
    function totalReserves(bytes32 normalizedToken) public view returns(uint) {
        return zTokenSnapshots[normalizedToken].totalReserves;
    }
    function totalSupply(bytes32 normalizedToken) public view returns(uint) {
        return zTokenSnapshots[normalizedToken].totalSupply;
    }
    // function accountBalance(uint64 branchChainId, address token, address owner) external view returns (uint balance) {
    //     bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
    //     (MathError mErr, uint exchangeRateMantissa) = exchangeRateStoredInternal(normalizedToken);
    //     require(mErr == MathError.NO_ERROR, "exchangeRateStored could not be calculated");
    //     (mErr, balance) = mulScalarTruncate(Exp({mantissa: exchangeRateMantissa}), accountTokens[normalizedToken][owner]);
    //     require(mErr == MathError.NO_ERROR, "balance could not be calculated");
    //     return balance;
    // }
    // function borrowBalanceStored(uint64 branchChainId, address token, address account) public view returns (uint) {
    //     bytes32 normalizedToken = Codec.encodeBranchToken(branchChainId, token);
    //     (MathError err, uint result) = borrowBalanceStoredInternal(normalizedToken, account);
    //     require(err == MathError.NO_ERROR, "borrowBalanceStored: borrowBalanceStoredInternal failed");
    //     return result;
    // }
}