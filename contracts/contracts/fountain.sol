// SPDX-License-Identifier: Proprietary

pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "./weth.sol";

contract Fountain is Ownable, Pausable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    // mainnet | 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
    // polygon | 0x0d500b1d8e8ef31e21c99d1db9a6444d3adf1270
    IWETH public immutable WETH9;

    // mainnet | 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // polygon | 0x2791bca1f2de4661ed88a30c99a7a9449aa84174
    IERC20 public immutable USDC;
    
    // create2 ensures the same address on all available networks
    // mainnet | 0xE592427A0AEce92De3Edee1F18E0157C05861564
    // polygon | 0xE592427A0AEce92De3Edee1F18E0157C05861564
    ISwapRouter public immutable swapRouter;

    uint256 private ephemeralGasMoneyAmount;
    
    mapping (address => uint256) private balances;

    mapping (string => address) private charities;
    mapping (address => string) private charitiesReverse;
    string[] private charityNames;
    EnumerableSet.AddressSet private charityAddresses;

    event FountainDeposit(
        address indexed donor, 
        address indexed ephemeralWallet, 
        address indexed tokenIn, 
        uint256 tokenAmountIn,
        uint256 gasOut,
        uint256 usdcOut
    );

    event FountainDonation(
        address indexed donor, 
        string indexed charity, 
        address indexed charityAddress, 
        uint256 usdcAmount
    );

    event FountainFinalization(
        address indexed donor,
        uint256 usdcAmount
    );

    constructor(ISwapRouter _swapRouter, uint256 _ephemeralGasMoneyAmount, IWETH _weth9, IERC20 _usdc) {
        swapRouter = _swapRouter;
        ephemeralGasMoneyAmount = _ephemeralGasMoneyAmount;
        WETH9 = _weth9;
        USDC = _usdc;
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
                tokenOut: address(WETH9),
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
        WETH9.withdraw(ephemeralGasMoneyAmount);

        // Send to ephemeralGasMoneyAmount to ephemeral wallet
        (bool ephemeralGasSent, ) = payable(ephemeralWalletAddress).call{value: ephemeralGasMoneyAmount}("");
        require(ephemeralGasSent, "Failed to send gas to ephemeral wallet.");

        // Calculate remaining amount of token to swap for USDC
        uint256 remainingAmountIn = totalAmountIn - tokenAmountSpentOnEthSwap;
        
        // Create params to swap remaining token amount for USDC
        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: address(USDC),
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
        
        emit FountainDeposit(msg.sender, ephemeralWalletAddress, tokenIn, totalAmountIn, ephemeralGasMoneyAmount, amountOut);
    }

    // invariants:
    //  * params
    //      - user == msg.sender || msg.sender == owner()
    //  * begin:
    //      - balances[msg.sender] == 0
    //  * end:
    //      - balances[msg.sender] == 0
    function finalize(
        address user, 
        string[] memory charities_, 
        uint256[] memory amounts_
        ) public whenNotPaused nonReentrant {
        require(msg.sender == user || msg.sender == owner(), "Unauthorization finalization.");
        require(charities_.length == amounts_.length, "Charities and amounts arrays of different length.");

        uint256 totalUserAllocation = 0;
        for (uint8 i = 0; i < charities_.length; i++) {
            totalUserAllocation += amounts_[i];
            require(charities[charities_[i]] != address(0x0), "Attempt to donate to unknown charity.");
        }

        require(totalUserAllocation <= balances[user], "Total finalization amount too high");

        uint256 totalDonated = 0;
        for (uint8 i = 0; i < charities_.length; i++) { 
            // amounts_[i]                          | user-requested donation amount to this charity 
            // balances[user] - totalUserAllocation | remaining amount after summing up all user-requested donations
            // amounts_[i] / totalUserAllocation    | ratio of user donation sent to this charity
            uint256 transferAmount = amounts_[i] + (balances[user] - totalUserAllocation) * (amounts_[i] / totalUserAllocation);

            // fix any uint math rounding errors by sending entire remaining amount to last charity
            if (i == charities_.length - 1) {
                transferAmount = balances[user] - totalDonated;
            }
            
            bool transferSuccess = USDC.transfer(charities[charities_[i]], transferAmount);
            require(transferSuccess, "USDC transfer to charity failed.");
            emit FountainDonation(user, charities_[i], charities[charities_[i]], transferAmount);

            totalDonated += transferAmount;
        }

        require(totalDonated == balances[user], "Must finalize entire balance");
    }

    function registerCharity(string memory charityName, address charityAddress) public {
        require(charities[charityName] == address(0x0), "Charity name already registered.");
        require(bytes(charitiesReverse[charityAddress]).length == 0, "Charity address already registered.");
        charities[charityName] = charityAddress;
        charityAddresses.add(charityAddress);
        charityNames.push(charityName);
    }

    function getCharityAddresses() public view returns (address[] memory charityAddresses_) {
        charityAddresses_ = charityAddresses.values();
    }

    function getCharityNames() public view returns (string[] memory charityNames_){
        charityNames_ = charityNames;
    }

    function getBalance(address user) public view returns (uint256 userBalance_) {
        userBalance_ = balances[user];
    }

    function setEphemeralGasAmount(uint256 newEphemeralGasMoneyAmount) public onlyOwner {
        ephemeralGasMoneyAmount = newEphemeralGasMoneyAmount;
    }

    function getEphemeralGasAmount() public view returns (uint256 ephemeralGasMoneyAmount_) {
        ephemeralGasMoneyAmount_ = ephemeralGasMoneyAmount;
    }
}