// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/access/Ownable.sol";

abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
}

library TransferHelper {
    /// @notice Transfers tokens from the targeted address to the given destination
    /// @notice Errors with 'STF' if transfer fails
    /// @param token The contract address of the token to be transferred
    /// @param from The originating address from which the tokens will be transferred
    /// @param to The destination address of the transfer
    /// @param value The amount to be transferred
    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                value
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "STF"
        );
    }

    /// @notice Transfers tokens from msg.sender to a recipient
    /// @dev Errors with ST if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param to The recipient of the transfer
    /// @param value The value of the transfer
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "ST"
        );
    }

    /// @notice Approves the stipulated contract to spend the given allowance in the given token
    /// @dev Errors with 'SA' if transfer fails
    /// @param token The contract address of the token to be approved
    /// @param to The target of the approval
    /// @param value The amount of the given token the target will be allowed to spend
    function safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.approve.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "SA"
        );
    }

    /// @notice Transfers ETH to the recipient address
    /// @dev Fails with `STE`
    /// @param to The destination of the transfer
    /// @param value The value to be transferred
    function safeTransferETH(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "STE");
    }
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

contract BaseSwap is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    ISwapRouter public swapRouter;
    address public targetContract;
    uint256 public minAmountOut;
    uint256 public amountIn;
    uint24 public poolFee;

    address public receiveTokenAddress; // 接收代币的地址
    mapping(address => bool) public whitelistedAddresses;

    // 首先添加事件
    event TokensPurchased(
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokensReceived
    );
    event DebugLog(string message, uint256 value);
    event WhitelistUpdated(address indexed account, bool indexed status);
    event MinAmountOutUpdated(uint256 oldAmount, uint256 newAmount);
    event PoolFeeUpdated(uint24 oldFee, uint24 newFee);
    event AmountInUpdated(uint256 oldAmount, uint256 newAmount);
    event ReceiveAddressUpdated(address oldAddress, address newAddress);
    event PausedStatusChanged(bool paused);
    event TargetContractUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    bool public paused;
    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    constructor(
        address _targetContract,
        address _swapRouter,
        uint24 _poolFee,
        address _receiveTokenAddress
    ) {
        require(_targetContract != address(0), "Invalid target contract");
        require(_swapRouter != address(0), "Invalid swap router");
        require(_poolFee > 0, "Invalid pool fee");
        require(msg.sender != address(0), "Invalid owner address");
        require(_receiveTokenAddress != address(0), "Invalid receive address");
        whitelistedAddresses[msg.sender] = true;
        targetContract = _targetContract;
        poolFee = _poolFee;
        swapRouter = ISwapRouter(_swapRouter);
        receiveTokenAddress = _receiveTokenAddress;
    }

    // Function to get daoToken address from target contract
    function getDaoToken() public view returns (address) {
        (bool success, bytes memory data) = targetContract.staticcall(
            abi.encodeWithSignature("daoToken()")
        );
        require(success, "Failed to call daoToken function");
        address token = abi.decode(data, (address));
        require(token != address(0), "DaoToken address is zero");
        return token;
    }

    function despWETH() external payable nonReentrant {
        require(msg.value > 0, "Invalid amount");
        IWETH(WETH).deposit{value: msg.value}();
        require(
            IWETH(WETH).balanceOf(address(this)) >= msg.value,
            "WETH deposit failed"
        );
        require(
            IERC20(WETH).transfer(msg.sender, msg.value),
            "Transfer failed"
        );
    }

    function getWETHBalance() public view returns (uint256) {
        return IWETH(WETH).balanceOf(address(this));
    }

    // Function to buy tokens using ETH through UniswapV3
    function buyTokens(uint256 amountIn) external nonReentrant whenNotPaused {
        address daoTokenAddress = getDaoToken();
        require(daoTokenAddress != address(0), "Dao address does not exist");
        require(amountIn > 0, "Invalid amount");
        require(
            amountIn <= IERC20(WETH).balanceOf(receiveTokenAddress),
            "Insufficient balance"
        );
        require(whitelistedAddresses[msg.sender], "Not whitelisted");
        TransferHelper.safeTransferFrom(
            WETH,
            receiveTokenAddress,
            address(this),
            amountIn
        );
        TransferHelper.safeApprove(WETH, address(swapRouter), amountIn);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: daoTokenAddress,
                fee: poolFee,
                recipient: receiveTokenAddress,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            });

        uint256 amountOut = swapRouter.exactInputSingle(params);
        require(
            amountOut >= minAmountOut,
            "Output amount is less than minimum required"
        );
    }

    function setMinAmountOut(uint256 _minAmount) external onlyOwner {
        require(_minAmount > 0, "Invalid amount");
        uint256 oldAmount = minAmountOut;
        minAmountOut = _minAmount;
        emit MinAmountOutUpdated(oldAmount, _minAmount);
    }

    function setPoolFee(uint24 _poolFee) external onlyOwner {
        require(_poolFee > 0, "Invalid amount");
        uint24 oldFee = poolFee;
        poolFee = _poolFee;
        emit PoolFeeUpdated(oldFee, _poolFee);
    }

    function setAmountIn(uint256 _amountIn) external onlyOwner {
        require(_amountIn > 0, "Invalid amount");
        uint256 oldAmount = amountIn;
        amountIn = _amountIn;
        emit AmountInUpdated(oldAmount, _amountIn);
    }

    // Function to withdraw any stuck tokens (emergency function)
    function withdrawToken(address token) external onlyOwner {
        // 建议添加地址检查
        require(token != address(0), "Invalid token address");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        require(IERC20(token).transfer(owner(), balance), "Transfer failed");
    }

    function withdrawETH() external nonReentrant onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = owner().call{value: balance}("");
        require(success, "ETH transfer failed");
    }

    function setReceiveTokenAddress(
        address _receiveAddress
    ) external onlyOwner {
        require(_receiveAddress != address(0), "Invalid address");
        address oldAddress = receiveTokenAddress;
        receiveTokenAddress = _receiveAddress;
        emit ReceiveAddressUpdated(oldAddress, _receiveAddress);
    }

    modifier onlyWhitelisted() {
        require(whitelistedAddresses[msg.sender], "Not whitelisted");
        _;
    }

    // 添加/移除白名单地址
    function setWhitelist(address account, bool status) external onlyOwner {
        require(account != address(0), "Invalid address");
        whitelistedAddresses[account] = status;
        emit WhitelistUpdated(account, status);
    }

    // 2. 缺少查询白名单状态的函数
    function isWhitelisted(address account) external view returns (bool) {
        return whitelistedAddresses[account];
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedStatusChanged(_paused);
    }

    // Required to receive ETH

    // 添加查询功能
    function getContractInfo()
        external
        view
        returns (
            address _targetContract,
            address _swapRouter,
            uint24 _poolFee,
            uint256 _minAmountOut,
            uint256 _amountIn,
            address _receiveTokenAddress
        )
    {
        return (
            targetContract,
            address(swapRouter),
            poolFee,
            minAmountOut,
            amountIn,
            receiveTokenAddress
        );
    }

    function setTargetContract(address _targetContract) external onlyOwner {
        require(
            _targetContract != address(0),
            "Invalid target contract address"
        );
        address oldAddress = targetContract;
        targetContract = _targetContract;
        emit TargetContractUpdated(oldAddress, _targetContract);
    }
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}
