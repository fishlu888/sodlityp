// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.0/contracts/access/Ownable.sol";

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

interface IUniswapV3Factory {
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address pool);
}

contract BaseSwap is Ownable {
    using SafeERC20 for IERC20;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    ISwapRouter public swapRouter;

    address public immutable targetContract;

    // Pool fee tier (1%)
    uint24 public constant poolFee = 10000;

    // 首先添加事件
    event TokensPurchased(
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokensReceived
    );
    event DebugLog(string message, uint256 value);

    constructor(address _targetContract, address _swapRouter) {
        targetContract = _targetContract;
        swapRouter = ISwapRouter(_swapRouter);
    }

    // Function to get daoToken address from target contract
    function getDaoToken() public view returns (address) {
        (bool success, bytes memory data) = targetContract.staticcall(
            abi.encodeWithSignature("daoToken()")
        );
        require(success, "Failed to get daoToken address");
        return abi.decode(data, (address));
    }

    function despWETH() external payable {
        // 将 ETH 转换为 WETH
        IWETH(WETH).deposit{value: msg.value}();

        require(
            IWETH(WETH).balanceOf(address(this)) >= msg.value,
            "Deposit failed"
        );

        // 将 WETH 转给消息发送者
        require(
            IERC20(WETH).transfer(msg.sender, msg.value),
            "Transfer failed"
        );
    }

    function getWETHBalance() public view returns (uint256) {
        return IWETH(WETH).balanceOf(address(this));
    }

    function test(uint256 amountIn) external {
        require(
            IERC20(WETH).transferFrom(msg.sender, address(this), amountIn),
            "Transfer failed"
        );
    }

    function getPoolAddress(
        address tokenA,
        address tokenB,
        uint24 fee,
        address factoryAddress
    ) external view returns (address pool) {
        // 获取 Uniswap V3 工厂合约实例
        IUniswapV3Factory factory = IUniswapV3Factory(factoryAddress);

        // 调用工厂合约的 getPool 方法获取池子地址
        pool = factory.getPool(tokenA, tokenB, fee);

        // 确保池子存在
        require(pool != address(0), "Pool does not exist");

        return pool;
    }

    // Function to buy tokens using ETH through UniswapV3
    function buyTokens(uint256 amountIn) external {
        address daoTokenAddress = getDaoToken();
        TransferHelper.safeTransferFrom(
            WETH,
            msg.sender,
            address(this),
            amountIn
        );

        TransferHelper.safeApprove(WETH, address(swapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: daoTokenAddress,
                fee: poolFee,
                recipient: msg.sender,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        uint256 amountOut = swapRouter.exactInputSingle(params);
    }

    // Function to withdraw any stuck tokens (emergency function)
    function withdrawToken(address token) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        IERC20(token).safeTransfer(msg.sender, balance);
    }

    // Function to withdraw any stuck ETH (emergency function)
    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = msg.sender.call{value: balance}("");
        require(success, "ETH transfer failed");
    }

    // Required to receive ETH
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}
