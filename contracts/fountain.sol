// SPDX-License-Identifier: Proprietary

pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";

contract Serenity is Ownable, Pausable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    address public constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    ISwapRouter public immutable swapRouter;
    uint256 ephemeralGasMoneyAmount;
    
    mapping (address => uint256) private balances;
    mapping (uint8 => address) private charities;

    constructor(ISwapRouter _swapRouter, uint256 _ephemeralGasMoneyAmount) {
        swapRouter = _swapRouter;
        ephemeralGasMoneyAmount = _ephemeralGasMoneyAmount;
    }

    function deposit(
        // params unrelated to swap
        address ephemeralWalletAddress,
        // shared swap params
        address tokenIn,
        uint256 totalAmountIn, 
        uint256 deadline,
        // eth swap params
        uint256 ethSwapAmountInMax,
        uint24 ethSwapPoolFee,
        // usdc swap params
        uint24 usdcSwapPoolFee,
        uint256 usdcSwapAmountOutMinimum
        ) public whenNotPaused nonReentrant {

        // Transfer the specified amount of token to this contract.
        TransferHelper.safeTransferFrom(tokenIn, msg.sender, address(this), totalAmountIn);
        
        // Approve router to spend totalAmountIn from this contract
        TransferHelper.safeApprove(tokenIn, address(swapRouter), totalAmountIn);

        // Construct "exact output" swap params to get some gas moneys.
        ISwapRouter.ExactOutputSingleParams memory ethSwapParams =
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: tokenIn,
                tokenOut: WETH9,
                fee: ethSwapPoolFee,
                recipient: address(this),
                deadline: deadline,
                amountOut: ephemeralGasMoneyAmount,
                amountInMaximum: ethSwapAmountInMax,
                // inactive, but this value can be used to set the limit for the price the swap will push the pool to,
                // which can help protect against price impact or for setting up logic in a variety of price-relevant mechanisms.
                sqrtPriceLimitX96: 0
            });

        // Executes the gas money swap returning the amountIn needed to spend to receive the desired amountOut.
        uint256 tokenAmountSpentOnEthSwap = swapRouter.exactOutputSingle(ethSwapParams);

        // Unwrap WETH9
        IWETH(WETH9).withdraw(ephemeralGasMoneyAmount);

        // Send to ephemeralGasMoneyAmount to ephemeral wallet
        (bool ephemeralGasSent, ) = payable(ephemeralWalletAddress).call{value: ephemeralGasMoneyAmount}("");
        require(ephemeralGasSent, "Failed to send gas to ephemeral wallet.");

        // Calculate remaining amount of token to swap for USDC
        uint256 remainingAmountIn = totalAmountIn - tokenAmountSpentOnEthSwap;
        
        // Create params to swap remaining token amount for USDC
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: USDC,
                fee: usdcSwapPoolFee,
                recipient: address(this),
                deadline: deadline,
                amountIn: remainingAmountIn,
                amountOutMinimum: usdcSwapAmountOutMinimum,
                // inactive, but this value can be used to set the limit for the price the swap will push the pool to,
                // which can help protect against price impact or for setting up logic in a variety of price-relevant mechanisms.
                sqrtPriceLimitX96: 0 
            });

        // How much USDC we got
        uint256 amountOut = swapRouter.exactInputSingle(params); 
        
        balances[ephemeralWalletAddress] += amountOut;
    }

    function finalize(
        address user, 
        uint8[] memory charities_, 
        uint256[] memory amounts_, 
        bool autoAllocateRemainder
        ) public whenNotPaused nonReentrant {

        require(charities_.length == amounts_.length, "Charities and amounts arrays of different length.");

        uint256 amountsSum = 0;
        for (uint256 i = 0; i < amounts_.length; i++) {
            amountsSum += amounts_[i];
        }

        require(amountsSum <= balances[user], "Total finalization amount too high");
        require(autoAllocateRemainder || amountsSum == balances[user], "Total finalization amount too low.");
        
        for (uint256 i = 0; i < charities_.length; i++) { 
            bool transferSuccess = IERC20(USDC).transfer(charities[charities_[i]], amounts_[i]);
            require(transferSuccess, "USDC transfer to charity failed.");
        }

        // deal with autoAllocateRemainder
    }

    function getBalance(address user) public view returns (uint256 userBalance_) {
        userBalance_ = balances[user];
    }
}