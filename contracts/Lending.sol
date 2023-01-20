// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

error TransferFailed();
error NeedsMoreThanZero();
error TokenNotAllowed(address token);

contract Lender is ReentrancyGuard, Ownable {
    /**
     * State variables
     */

    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant MIN_HEALH_FACTOR = 1e18;

    address[] public allowedTokens;
    mapping(address => address) public tokenToPriceFeed;
    // Account --> Token --> Amount (Deposited)
    mapping(address => mapping(address => uint256))
        public accountToTokenDeposits;
    // Account --> Token --> Amount (Borrowed)
    mapping(address => mapping(address => uint256))
        public accountToTokenBorrows;

    /**
     * Constructor
     */
    constructor() {}

    /**
     * External and public functions
     */

    function deposit(
        address token,
        uint256 amount
    ) external nonReentrant moreThanZero(amount) isAllowedToken(token) {
        bool success = ERC20(token).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) {
            revert TransferFailed();
        }
        accountToTokenDeposits[msg.sender][token] += amount;
        emit Deposit(msg.sender, token, amount);
    }

    function withdraw(
        address token,
        uint256 amount
    ) external nonReentrant moreThanZero(amount) isAllowedToken(token) {
        if (accountToTokenDeposits[msg.sender][token] < amount) {
            revert TransferFailed();
        }
        pullFunds(msg.sender, token, amount);
        // Healthfactor
        require(
            healthFactor(msg.sender) >= MIN_HEALH_FACTOR,
            "WARNING: Platform will go  insolvent!"
        );
        emit Withdraw(msg.sender, token, amount);
    }

    function borrow(
        address token,
        uint256 amount
    ) external nonReentrant moreThanZero(amount) isAllowedToken(token) {
        require(
            ERC20(token).balanceOf(address(token)) >= amount,
            "Not enough tokens to borrow"
        );
        require(
            healthFactor(msg.sender) >= MIN_HEALH_FACTOR,
            "WARNING: Platform will go insolvent!"
        );
        bool success = ERC20(token).transfer(msg.sender, amount);
        if (!success) {
            revert TransferFailed();
        }
        accountToTokenBorrows[msg.sender][token] += amount;
        emit Borrow(msg.sender, token, amount);
    }

    function repay(
        address token,
        uint256 amount
    ) external nonReentrant moreThanZero(amount) isAllowedToken(token) {
        _repay(msg.sender, token, amount);
        emit Repay(msg.sender, token, amount);
    }

    function getEthValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            tokenToPriceFeed[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // 500000000000000 ETH (Wei) per DAI <--- Price
        // 5000 DAI <-- Amount
        // Amount(DAI) * Price(ETH/DAI) = ETH value
        // 5000 DAI * 500000000000000 Wei/DAI = 2500000000000000000 Wei / 1e18 Wei =  2.5 ETH
        return (uint256(price) * amount) / 1e18;
    }

    function getTokenValueFromEth(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            tokenToPriceFeed[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // 500000000000000 ETH (Wei) per DAI <--- Price
        // 5000 DAI <-- Amount
        // Amount(DAI) / Price(ETH/DAI) = DAI per ETH
        // 5000 DAI * 1e18 / 2.5 ETH = 2000 DAI per ETH
        return (amount * 1e18) / uint256(price);
    }

    function getAccountCollateralValue(
        address account
    ) public view returns (uint256) {
        uint256 totalCollateralValueInEth = 0;
        for (uint256 index = 0; index < allowedTokens.length; index++) {
            address token = allowedTokens[index];
            uint256 amount = accountToTokenDeposits[account][token];
            uint256 valueInEth = getEthValue(token, amount);
            totalCollateralValueInEth += valueInEth;
        }
        return totalCollateralValueInEth;
    }

    function getAccountBorrowedValue(
        address account
    ) public view returns (uint256) {
        uint256 totalBorrowsValueInEth = 0;
        for (uint256 index = 1; index < allowedTokens.length; index++) {
            address token = allowedTokens[index];
            uint256 amount = accountToTokenBorrows[account][token];
            uint256 valueInEth = getEthValue(token, amount);
            totalBorrowsValueInEth += valueInEth;
        }
        return totalBorrowsValueInEth;
    }

    function getAccountInformation(
        address account
    ) public view returns (uint256, uint256) {
        uint256 collateralValueInEth = getAccountCollateralValue(account);
        uint256 borrowedValueInEth = getAccountBorrowedValue(account);
        return (collateralValueInEth, borrowedValueInEth);
    }

    function healthFactor(address account) public view returns (uint256) {
        (
            uint256 collateralValueInEth,
            uint256 borrowedValueInEth
        ) = getAccountInformation(account);
        uint256 collateralAdjustedToThreshold = collateralValueInEth *
            (LIQUIDATION_THRESHOLD / 100);
        if (borrowedValueInEth == 0) {
            return 100e18;
        }
        return (collateralAdjustedToThreshold * 1e18) / borrowedValueInEth;
    }

    function setAllowedToken(address token, address priceFeed) external {
        bool foundToken = false;
        for (uint256 index = 0; index < allowedTokens.length; index++) {
            if (allowedTokens[index] == token) {
                foundToken = true;
                break;
            }
        }
        if (!foundToken) {
            allowedTokens.push(token);
        }

        tokenToPriceFeed[token] = priceFeed;
        emit AllowedToken(token, priceFeed);
    }

    /**
     * Private and internal function
     */

    function pullFunds(address account, address token, uint256 amount) private {
        require(
            accountToTokenDeposits[account][token] >= amount,
            "Not enough funds to withdraw"
        );
        bool success = ERC20(token).transfer(account, amount);
        if (!success) {
            revert TransferFailed();
        }
        accountToTokenDeposits[account][token] -= amount;
    }

    function _repay(address account, address token, uint256 amount) private {
        accountToTokenBorrows[account][token] -= amount;
        bool success = ERC20(token).transferFrom(
            account,
            address(this),
            amount
        );
        if (!success) {
            revert TransferFailed();
        }
    }

    /**
     * Modifiers
     */

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (tokenToPriceFeed[token] == address(0)) {
            revert TokenNotAllowed(token);
        }
        _;
    }

    /**
     * Events
     */
    event Deposit(
        address indexed account,
        address indexed token,
        uint256 indexed amount
    );
    event Withdraw(
        address indexed account,
        address indexed token,
        uint256 indexed amount
    );
    event Borrow(
        address indexed account,
        address indexed token,
        uint256 indexed amount
    );
    event Repay(
        address indexed account,
        address indexed token,
        uint256 indexed amount
    );
    event AllowedToken(address indexed token, address indexed priceFeed);
}
