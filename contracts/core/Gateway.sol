// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import "./Codec.sol";
import "./CrossChainGovernance.sol";
import "../libs/token/ERC20/utils/SafeERC20.sol";
import "../libs/token/ERC20/IERC20.sol";
import "../libs/security/ReentrancyGuard.sol";

contract Gateway is Branch, ReentrancyGuard {
    using SafeERC20 for IERC20;

    constructor(address _managerContractAddress, bytes memory _coreAddress, uint64 _coreChainId) {
        managerContractAddress = _managerContractAddress;
        coreAddress = _coreAddress;
        coreChainId = _coreChainId;
        tokens[SENTINEL_TOKEN] = SENTINEL_TOKEN;
    }

    address constant ETH_ADDRESS = address(0);
    uint256 internal tokenCount;
    address internal constant SENTINEL_TOKEN = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    mapping(address => address) public tokens;
    mapping(address => bool) public tokenDepositEnabled; 
    mapping(address => bool) public tokenBorrowEnabled;
    bool public marketDepositEnbaled = true;
    bool public marketBorrowEnbaled = true;

    event AddNewTokenEvent(address token);
    event ManageDepositEvent(bool isEnable, bool applyToAll, address token);
    event ManageBorrowEvent(bool isEnable, bool applyToAll, address token);
    event DepositEvent(address userAddress, address token, uint256 amount);
    event WithdrawRequestEvent(address userAddress, address token, uint256 amount);
    event WithdrawEvent(address userAddress, address token, uint256 amount);
    event BorrowEvent(address userAddress, address token, uint256 amount);
    event RepayBorrowEvent(address userAddress, address token, uint256 amount);


    // public functions
    function deposit(address token, uint amount) external nonReentrant {
        _checkDeposit(msg.sender, token, amount);

        _transferToContract(token, amount);

        sendMessageToCore(Codec.encodeDepositMessage(msg.sender, token, amount));

        emit DepositEvent(msg.sender, token, amount);
    }

    function withdraw(address token, uint amount) external nonReentrant {
        _checkWithdraw(msg.sender, token, amount);

        sendMessageToCore(Codec.encodeWithdrawMessage(msg.sender, token, amount));

        emit WithdrawRequestEvent(msg.sender, token, amount);
    }

    function borrow(address token, uint amount) external nonReentrant {
        _checkBorrow(msg.sender, token, amount);

        sendMessageToCore(Codec.encodeBorrowMessage(msg.sender, token, amount));

        emit BorrowEvent(msg.sender, token, amount);
    }

    function repayBorrow(address token, uint amount) external nonReentrant {
        _checkRepayBorrow(msg.sender, token, amount);

        _transferToContract(token, amount);

        sendMessageToCore(Codec.encodeRepayBorrowMessage(msg.sender, token, amount));

        emit RepayBorrowEvent(msg.sender, token, amount);
    }

    function getTokens() public view returns (address[] memory) {
        address[] memory tokenArray = new address[](tokenCount);
        uint256 index = 0;
        address currentToken = tokens[SENTINEL_TOKEN];
        while (currentToken != SENTINEL_TOKEN) {
            tokenArray[index] = currentToken;
            currentToken = tokens[currentToken];
            index++;
        }
        return tokenArray;
    }


    // handler
    function handleCoreMessage(bytes memory message) override internal {
        Codec.TAG tag = Codec.getTag(message);
        if (Codec.compareTag(tag, Codec.WITHDRAW_TAG)) {
            (address toAddress, address token, uint256 amount) = Codec.decodeWithdrawMessage(message);
            _transferFromContract(token, toAddress, amount);
            emit WithdrawEvent(toAddress, token, amount);
        } else if (Codec.compareTag(tag, Codec.MANAGE_DEPOSIT_TAG)) {
            (bool isEnable, bool applyToAll, address token) = Codec.decodeManageDepositMessage(message);
            if (applyToAll) {
                marketDepositEnbaled = isEnable;
            } else { 
                if (tokens[token] == address(0)) {
                    _addToken(token);
                    emit AddNewTokenEvent(token);
                }   
                tokenDepositEnabled[token] = isEnable;
            }
            emit ManageDepositEvent(isEnable, applyToAll, token);
        } else if (Codec.compareTag(tag, Codec.MANAGE_BORROW_TAG)) {
            (bool isEnable, bool applyToAll, address token) = Codec.decodeManageBorrowMessage(message);
            if (applyToAll) {
                marketBorrowEnbaled = isEnable;
            } else { 
                if (tokens[token] == address(0)) {
                    _addToken(token);
                    emit AddNewTokenEvent(token);
                }   
                tokenBorrowEnabled[token] = isEnable;
            }
            emit ManageBorrowEvent(isEnable, applyToAll, token);
        } else {
            revert("Unknown message tag");
        }
    }

    // internal functions
    function _addToken(address newToken) internal {
        require(newToken != SENTINEL_TOKEN, "Invalid token address provided");
        if (tokens[newToken] != address(0)) { return; } 
        tokens[newToken] = tokens[SENTINEL_TOKEN];
        tokens[SENTINEL_TOKEN] = newToken;
        tokenCount++;
    }
    
    function _removeToken(address tokenAddress) internal {
        require(tokenAddress != SENTINEL_TOKEN, "Invalid token address provided");
        if (tokens[tokenAddress] == address(0)) { return; }
        address prevToken = tokens[SENTINEL_TOKEN];
        for (;tokens[prevToken] != tokenAddress;) {
            prevToken = tokens[prevToken];
        }
        tokens[prevToken] = tokens[tokenAddress];
        tokens[tokenAddress] = address(0);
        tokenCount--;
    }

    function _checkDeposit(address userAddress, address token, uint amount) internal view {
        userAddress;
        amount;

        require(tokens[token] != address(0), "Invalid token");
        require(tokenDepositEnabled[token] && marketDepositEnbaled, "Deposit disabled");
    }

    function _checkWithdraw(address userAddress, address token, uint amount) internal view {
        userAddress;

        require(tokens[token] != address(0), "Invalid token");
        require(amount <= IERC20(token).balanceOf(address(this)), "Insufficient token balance in gateway contract");
    }

    function _checkBorrow(address userAddress, address token, uint amount) internal view {
        userAddress;
        amount;

        require(tokens[token] != address(0), "Invalid token");
        require(tokenBorrowEnabled[token] && marketBorrowEnbaled, "Borrow disabled");
        require(amount <= IERC20(token).balanceOf(address(this)), "Insufficient token balance in gateway contract");
    }

    function _checkRepayBorrow(address userAddress, address token, uint amount) internal view {
        userAddress;
        amount;

        require(tokens[token] != address(0), "Invalid token");
    }

    function _transferToContract(address token, uint256 amount) internal {
        if (token == ETH_ADDRESS) {
            require(msg.value != 0, "transferred ether cannot be zero!");
            require(msg.value == amount, "transferred ether is not equal to amount!");
        } else {
            require(msg.value == 0, "there should be no ether transfer!");
            require(amount!=0,"amount is 0");
            IERC20 erc20Token = IERC20(token);
            uint beforeTransfer=IERC20(token).balanceOf(address(this));
            erc20Token.safeTransferFrom(msg.sender,address(this), amount);
            uint afterTransfer=IERC20(token).balanceOf(address(this));
            require(afterTransfer==beforeTransfer+amount,"balance is incorrect");
        }
    }

    function _transferFromContract(address token, address toAddress, uint256 amount) internal {
        if (token == ETH_ADDRESS) {
            require(amount <= address(this).balance, "Insufficient balance in gateway contract");
            payable(address(uint160(toAddress))).transfer(amount);
        } else {
            require(amount <= IERC20(token).balanceOf(address(this)), "Insufficient balance in gateway contract");
            IERC20 erc20Token = IERC20(token);
            uint beforeTransfer=IERC20(token).balanceOf(address(this));
            erc20Token.safeTransfer(toAddress, amount);
            uint afterTransfer=IERC20(token).balanceOf(address(this));
            require(afterTransfer==beforeTransfer-amount,"balance is incorrect");
        }
    }
}