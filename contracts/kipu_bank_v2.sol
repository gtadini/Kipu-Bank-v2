// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/**
 * @title Kipu Bank ETH-USDC
 * @notice A secure banking smart contract multi-token
 * @notice This is a contract for educational purposes.
 * @author Tadini Gabriel
 * @custom:security Do not use in production.
 */

/*///////////////////////////////////
             Imports
///////////////////////////////////*/
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/*///////////////////////////////////
            Libraries
///////////////////////////////////*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/*///////////////////////////////////
            Interfaces
///////////////////////////////////*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract KipuBank is AccessControl {
    /*///////////////////////////////////
            Type Declarations
///////////////////////////////////*/
    /// @notice Role for treasury management and bank limit administration.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice Applies SafeERC20 secure functions to all IERC20 interactions.
    using SafeERC20 for IERC20;

    /// @notice Applies IERC20Metadata secure functions to all SafeERC20 interactions.
    using SafeERC20 for IERC20Metadata;

    /*///////////////////////////////////
    Inmutable variables - constants
///////////////////////////////////*/
    /// @notice The maximum total value (in USD equivalent, 6 decimals) the bank can hold.
    uint256 public immutable i_bankCapInUSD;

    ///@notice constant variable to store the Data Feed heartbeat, expressed in seconds
    uint16 constant ORACLE_HEARTBEAT = 3600;

    /// @notice Decimal factor for internal accounting (1 * 10^6), simulating the USDC base.
    uint256 public constant INTERNAL_DECIMALS = 1 * 10 ** 6;

    /// @notice Conversion factor for scaling ETH (18 dec) to USD (6 dec) using a price of 8 dec.
    uint256 public constant ETH_TO_USD_CONVERSION_FACTOR = 1 * 10 ** 20;

    /// @notice Special address used to represent native Ether in the internal accounting mapping.
    address public constant ETH_TOKEN_ADDRESS = address(0);

    /*///////////////////////////////////
           State variables
///////////////////////////////////*/
    /// @notice Instancia de storage del Chainlink Data Feed (ETH/USD).
    AggregatorV3Interface public s_priceFeed;

    // @notice Nested mapping to store each user's balance per token.
    mapping(address => mapping(address => uint256)) public s_balances;

    // @notice The current total value (in USD equivalent) deposited in the bank.
    uint256 private s_totalDepositedInUSD;

    /// @notice Counter for the total number of successful deposits made.
    uint256 public s_depositCount;

    /*///////////////////////////////////
               Events
///////////////////////////////////*/
    /// @notice Event emitted when a user successfully deposits.
    event DepositMade(
        address indexed user,
        address indexed token,
        uint256 rawAmount,
        uint256 usdValue
    );

    /// @notice Event emitted when any asset is successfully withdrawn by a user.
    event WithdrawalMade(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /// @notice Event emitted when a manager withdraws funds from the bank treasury.
    event TreasuryWithdrawal(
        address indexed manager,
        address indexed token,
        uint256 amount
    );

    /// @notice Event emitted when the Chainlink Price Feed address is updated.
    event PriceFeedUpdated(address indexed oldFeed, address indexed newFeed);

    /*///////////////////////////////////
               Errors
///////////////////////////////////*/
    /// @notice Error thrown when a native or ERC20 transfer transaction fails.
    error KipuBank_TransferFailed();

    /// @notice Error thrown when the deposit exceeds the global limit in USD.
    error KipuBank_GlobalLimitExceeded(
        uint256 cap,
        uint256 current,
        uint256 depositValue
    );

    /// @notice Error thrown when a user attempts to withdraw more than their balance.
    error KipuBank_InsufficientFunds(
        address user,
        address token,
        uint256 actual,
        uint256 attempt
    );

    /// @notice Error thrown if the oracle price is invalid or stale.
    error KipuBank_StaleOrCompromisedPrice();

    /*///////////////////////////////////
            Modifiers
///////////////////////////////////*/
    /**
     * @notice Modifier that restricts function access to addresses with the MANAGER_ROLE.
     */
    modifier onlyManager() {
        // AccessControl provides the _checkRole function which handles the revert if the role is missing.
        _checkRole(MANAGER_ROLE, _msgSender());
        _;
    }

    /*///////////////////////////////////
            Functions
///////////////////////////////////*/

    /*///////////////////////////////////
            Constructor
///////////////////////////////////*/
    /**
     * @notice Constructor for the KipuBank contract, sets up roles, and immutable variables.
     * @param _bankCapInUSD The maximum global cap of the bank, in USD
     * @param _priceFeed The initial address of the Chainlink AggregatorV3Interface (e.g., ETH/USD).
     * @param _initialAdmin The initial administrator of the contract.
     */

    constructor(
        uint256 _bankCapInUSD,
        address _priceFeed,
        address _initialAdmin
    ) {
        // Initializes AccessControl and sets up roles.
        AccessControl._grantRole(
            AccessControl.DEFAULT_ADMIN_ROLE,
            _initialAdmin
        );
        AccessControl._grantRole(MANAGER_ROLE, _initialAdmin);

        i_bankCapInUSD = _bankCapInUSD;
        s_priceFeed = AggregatorV3Interface(_priceFeed);
    }

    /// @notice Allows users to deposit native ETH (18 decimals).
    function depositETH() external payable {
        _deposit(ETH_TOKEN_ADDRESS, msg.value, 18);
    }

    /**
     * @notice Allows users to deposit any ERC-20 token.
     * @dev Requires the user to have called `approve` on the token contract beforehand.
     * @param _token The address of the ERC-20 token to deposit.
     * @param _amount The amount of the token to deposit (in its native decimals).
     */
    function depositERC20(address _token, uint256 _amount) external {
        if (_token == ETH_TOKEN_ADDRESS) revert KipuBank_TransferFailed();

        // Fetches native token decimals.
        uint8 tokenDecimals = IERC20Metadata(_token).decimals();

        // 1. INTERACTION: Move tokens from the user to the contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // 2. EFFECTS: Internal accounting logic (which uses the 6 decimal base)
        _deposit(_token, _amount, tokenDecimals);
    }

    /*///////////////////////
        Withdrawal Function
    ///////////////////////*/

    /**
     * @notice Allows users to withdraw their deposited assets.
     * @param _token The token address to withdraw (address(0) for ETH).
     * @param _amount The amount of the token to withdraw (in its native decimals).
     */
    function withdraw(address _token, uint256 _amount) external {
        // 1. Determine native decimals and convert the requested amount to the internal base (6 decimals) for CHECK
        uint8 tokenDecimals = _token == ETH_TOKEN_ADDRESS
            ? 18
            : IERC20Metadata(_token).decimals();
        uint256 amountInInternalDecimals = _convertToInternalDecimals(
            _amount,
            tokenDecimals
        );

        // CHECKS: Verify sufficient internal balance
        if (s_balances[msg.sender][_token] < amountInInternalDecimals) {
            revert KipuBank_InsufficientFunds(
                msg.sender,
                _token,
                s_balances[msg.sender][_token],
                amountInInternalDecimals
            );
        }

        // EFFECTS: Update internal accounting (CEI pattern)
        s_balances[msg.sender][_token] -= amountInInternalDecimals;

        // INTERACTION: Transfer the asset to the user (using the native amount)
        if (_token == ETH_TOKEN_ADDRESS) {
            _transferEth(msg.sender, _amount);
        } else {
            IERC20(_token).safeTransfer(msg.sender, _amount);
        }

        emit WithdrawalMade(msg.sender, _token, _amount);
    }

    /*///////////////////////
        Administration Functions
    ///////////////////////*/

    /**
     * @notice Allows a MANAGER to withdraw all funds from the bank treasury.
     * @param _token The token address to withdraw (address(0) for ETH).
     */
    function managerWithdrawTreasury(address _token) external onlyManager {
        // MODIFIER APPLIED
        // CHECKS (Modifier handles role check)

        // EFFECTS & INTERACTIONS
        if (_token == ETH_TOKEN_ADDRESS) {
            uint256 balance = address(this).balance;
            _transferEth(msg.sender, balance);
            emit TreasuryWithdrawal(msg.sender, _token, balance);
        } else {
            // Withdraw the total balance of that ERC-20 token held by the contract.
            uint256 balance = IERC20(_token).balanceOf(address(this));
            IERC20(_token).safeTransfer(msg.sender, balance);
            emit TreasuryWithdrawal(msg.sender, _token, balance);
        }
    }

    /**
     * @notice Allows a MANAGER to update the Chainlink Price Feed address.
     * @param _newFeedAddress The new address of the AggregatorV3Interface.
     */
    function setPriceFeed(address _newFeedAddress) external onlyManager {
        // MODIFIER APPLIED
        // CHECKS (Modifier handles role check)

        // EFFECTS
        address oldFeed = address(s_priceFeed);
        s_priceFeed = AggregatorV3Interface(_newFeedAddress);

        // EMIT
        emit PriceFeedUpdated(oldFeed, _newFeedAddress);
    }

    /*///////////////////////
        Internal & Private Functions
    ///////////////////////*/

    /**
     * @notice Central internal logic for all deposits (ETH and ERC20).
     * @param _token The address of the deposited token.
     * @param _amount The deposit value in the token's native decimals.
     * @param _decimals The token's native decimals.
     */
    function _deposit(
        address _token,
        uint256 _amount,
        uint8 _decimals
    ) private {
        // 1. CHECKS: Conversion and Limit
        // Convert the deposited amount to the internal accounting base (6 decimals)
        uint256 amountInInternalDecimals = _convertToInternalDecimals(
            _amount,
            _decimals
        );

        // Convert the amount to equivalent USD value (also in 6 decimals) for cap checking
        uint256 usdValue = _token == ETH_TOKEN_ADDRESS
            ? _convertEthToUSD(amountInInternalDecimals)
            : _convertTokenToUSD( amountInInternalDecimals);

        uint256 newTotalInUSD = s_totalDepositedInUSD + usdValue;

        // Check global cap (both values are in 6 decimals)
        if (newTotalInUSD > i_bankCapInUSD) {
            revert KipuBank_GlobalLimitExceeded(
                i_bankCapInUSD,
                s_totalDepositedInUSD,
                usdValue
            );
        }

        // 2. EFFECTS: Update state
        s_balances[msg.sender][_token] += amountInInternalDecimals;
        s_totalDepositedInUSD = newTotalInUSD;

        // 3. EMIT:
        emit DepositMade(msg.sender, _token, _amount, usdValue);
    }

    /**
     * @notice Converts a token amount (in native decimals) to the internal base (6 decimals).
     * @param _amount The token value in its native decimals.
     * @param _nativeDecimals The token's native decimals (e.g., 18 for ETH, 6 for USDC).
     * @return The converted value in 6 decimals.
     */
    function _convertToInternalDecimals(
        uint256 _amount,
        uint8 _nativeDecimals
    ) internal pure returns (uint256) {
        uint8 internalDecimals = 6; // Internal accounting base

        if (_nativeDecimals == internalDecimals) {
            return _amount;
        } else if (_nativeDecimals < internalDecimals) {
            // Scale up: Amount * 10^(InternalDecimals - NativeDecimals)
            return _amount * (10 ** (internalDecimals - _nativeDecimals));
        } else {
            // Scale down: Amount / 10^(NativeDecimals - InternalDecimals)
            return _amount / (10 ** (_nativeDecimals - internalDecimals));
        }
    }

    /**
     * @notice Converts an ETH amount (which was already converted to 6 decimals) to its USD equivalent (6 decimals).
     * @dev To demonstrate decimal handling, we temporarily scale the input back to 18 decimals, apply the full 10^20 division, and get the 6-decimal result.
     * @param _ethAmountIn6Decimals The ETH amount in 6 decimals.
     * @return The USD equivalent value (6 decimals).
     */
    function _convertEthToUSD(
        uint256 _ethAmountIn6Decimals
    ) internal view returns (uint256) {
        // Price from oracle (8 decimals)
        uint256 ethUSDPrice = _getChainlinkPrice();

        // 1. Scale the 6-decimal amount back to 18 decimals (the original Wei representation)
        uint256 ethAmountIn18Decimals = _ethAmountIn6Decimals * 1e12;

        // 2. Apply the full formula for 6-decimal output: (Amount_18 * Price_8) / 10^20
        return
            (ethAmountIn18Decimals * ethUSDPrice) /
            ETH_TO_USD_CONVERSION_FACTOR;
    }

    /**
     * @notice Placeholder function to convert other tokens to USD.
     * @dev Assumes stablecoins (like USDC) are 1:1 with USD, and the input is already in 6 decimals.
     */
    function _convertTokenToUSD(
        uint256 _amountIn6Decimals
    ) internal pure returns (uint256) {
        return _amountIn6Decimals;
    }

    /**
     * @notice Queries the Chainlink Data Feed for the current ETH/USD price.
     * @return The ETH/USD price in 8 decimals.
     */
    function _getChainlinkPrice() private view returns (uint256) {
        // Uses the storage variable s_priceFeed
        (, int256 ethUSDPrice, , uint256 updatedAt, ) = s_priceFeed
            .latestRoundData();

        // Check price validity and staleness
        if (ethUSDPrice <= 0) revert KipuBank_StaleOrCompromisedPrice();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT)
            revert KipuBank_StaleOrCompromisedPrice();

        return uint256(ethUSDPrice);
    }

    /**
     * @notice Private function to securely transfer native ETH.
     */
    function _transferEth(address _recipient, uint256 _amount) private {
        (bool success, ) = _recipient.call{value: _amount}("");

        if (!success) {
            revert KipuBank_TransferFailed();
        }
    }

    /*////////////////////////
        Receive & Fallback
    /////////////////////////*/
    /// @notice The `receive` function directs incoming ETH to the deposit logic.
    receive() external payable {
        _deposit(ETH_TOKEN_ADDRESS, msg.value, 18);
    }
}
