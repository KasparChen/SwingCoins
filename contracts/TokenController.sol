// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// SwingA Token Contract
contract SwingA is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("SwingA", "SWGA") {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

// SwingB Token Contract
contract SwingB is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("SwingB", "SWGB") {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}

// Interfaces for token minting and Uniswap interaction
interface IToken {
    function mint(address to, uint256 value) external;
}

interface IUniswapV2Router02 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function WETH() external pure returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

// Main Contract for Staking, Liquidity, and Token Operations
contract Mud {
    using SafeMath for uint256;

    // Constants for token addresses and Uniswap
    address private constant TokenA = 0x6f780376B0b9C47b45fae617d74c5a0359cbBA11;
    address private constant TokenB = 0xF7e010F25c1e2Bac8C377F875F1575daF4Bebd4c;
    address private constant WETH = 0x4200000000000000000000000000000000000006;
    address private constant UniswapV2Router02Address = 0xf9E6284f46E40c91F31dCe60A79d7aEb243afF6B;

    uint256 public totalStakingRewardsA;
    uint256 public totalStakingRewardsB;

    uint256 public burnRate = 1;
    uint256 public lastBlock;
    uint256 public netValue;
    bool public isPositive = true;

    // Mapping for staking information
    mapping(address => uint256) public stakedTokenA;
    mapping(address => uint256) public stakedTokenB;
    mapping(address => uint256) public claimTokenATime;
    mapping(address => uint256) public claimTokenBTime;

    // Constructor
    constructor() {
        lastBlock = block.timestamp;

        // Approve maximum spending for tokens
        IERC20(TokenA).approve(UniswapV2Router02Address, type(uint256).max);
        IERC20(TokenB).approve(UniswapV2Router02Address, type(uint256).max);
        IERC20(WETH).approve(UniswapV2Router02Address, type(uint256).max);
    }

    // Event declarations
    event LiquidityAdded(uint256 ethAmount, uint256 tokenAmount, uint256 price);
    event SafeCheck(uint256 tokenBalance, uint256 lpToken, uint256 expETH, uint256 ethAmount);
    event UltraBurn(uint256 tokenAmount, uint256 ethAmount);
    event TextReturn(string message);

    // ultraMintA: Mint, swap 60%, and add liquidity for TokenA
    function ultraMintA() public {
        // Mint the specified net value of TokenA
        IToken(TokenA).mint(address(this), netValue);

        IUniswapV2Router02 router = IUniswapV2Router02(UniswapV2Router02Address);

        // Step 1: Swap 60% of the minted TokenA for WETH
        uint256 swapAmount = netValue.mul(60).div(100);
        _swapTokensForWETH(router, TokenA, swapAmount);

        // Step 2: Add liquidity to Uniswap with the remaining 40% TokenA and swapped WETH
        uint256 tokenBalance = IERC20(TokenA).balanceOf(address(this));
        uint256 ethAmount = IERC20(router.WETH()).balanceOf(address(this));

        uint256 liquidityPrice = _calculatePrice(router, TokenA);

        // Ensure enough usable TokenA for liquidity
        uint256 usableTokenA = IERC20(TokenA).totalSupply().sub(totalStakingRewardsA).sub(stakedTokenA[address(this)]);

        if (usableTokenA > 0) {
            _addLiquidity(router, TokenA, usableTokenA, ethAmount, liquidityPrice);
        } else {
            emit TextReturn("No usable TokenA for liquidity");
        }
    }

    // ultraMintB: Mint, swap 60%, and add liquidity for TokenB
    function ultraMintB() public {
        // Mint the specified net value of TokenB
        IToken(TokenB).mint(address(this), netValue);

        IUniswapV2Router02 router = IUniswapV2Router02(UniswapV2Router02Address);

        // Step 1: Swap 60% of the minted TokenB for WETH
        uint256 swapAmount = netValue.mul(60).div(100);
        _swapTokensForWETH(router, TokenB, swapAmount);

        // Step 2: Add liquidity to Uniswap with the remaining 40% TokenB and swapped WETH
        uint256 tokenBalance = IERC20(TokenB).balanceOf(address(this));
        uint256 ethAmount = IERC20(router.WETH()).balanceOf(address(this));

        uint256 liquidityPrice = _calculatePrice(router, TokenB);

        // Ensure enough usable TokenB for liquidity
        uint256 usableTokenB = IERC20(TokenB).totalSupply().sub(totalStakingRewardsB).sub(stakedTokenB[address(this)]);

        if (usableTokenB > 0) {
            _addLiquidity(router, TokenB, usableTokenB, ethAmount, liquidityPrice);
        } else {
            emit TextReturn("No usable TokenB for liquidity");
        }
    }

    // ultraBurnA: Remove liquidity, swap WETH back to TokenA, and burn
    function ultraBurnA() public {
        IUniswapV2Router02 router = IUniswapV2Router02(UniswapV2Router02Address);

        // Step 1: Remove liquidity from Uniswap
        uint256 ethAmount = _removeLiquidity(router, TokenA);

        // Step 2: Swap WETH back to TokenA
        uint256 tokenAmount = _swapTokensForTokens(router, router.WETH(), TokenA, ethAmount);

        // Step 3: Burn all retrieved TokenA
        IERC20(TokenA).transfer(address(0xdead), tokenAmount);
    }

    // ultraBurnB: Remove liquidity, swap WETH back to TokenB, and burn
    function ultraBurnB() public {
        IUniswapV2Router02 router = IUniswapV2Router02(UniswapV2Router02Address);

        // Step 1: Remove liquidity from Uniswap
        uint256 ethAmount = _removeLiquidity(router, TokenB);

        // Step 2: Swap WETH back to TokenB
        uint256 tokenAmount = _swapTokensForTokens(router, router.WETH(), TokenB, ethAmount);

        // Step 3: Burn all retrieved TokenB
        IERC20(TokenB).transfer(address(0xdead), tokenAmount);
    }

    // Swap tokens for WETH
    function _swapTokensForWETH(IUniswapV2Router02 router, address token, uint256 amount) private returns (uint256) {
        address[] memory path = new address ;
        path[0] = token;
        path[1] = router.WETH();

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );

        return IERC20(router.WETH()).balanceOf(address(this));
    }

    // Swap tokens for other tokens
    function _swapTokensForTokens(IUniswapV2Router02 router, address fromToken, address toToken, uint256 amount) private returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );

        return IERC20(toToken).balanceOf(address(this));
    }

    // Calculate token price in terms of ETH
    function _calculatePrice(IUniswapV2Router02 router, address token) private view returns (uint256) {
        uint256 liqEth = IERC20(router.WETH()).balanceOf(IUniswapV2Factory(router.factory()).getPair(token, router.WETH()));
        uint256 liqToken = IERC20(token).balanceOf(IUniswapV2Factory(router.factory()).getPair(token, router.WETH()));
        return liqToken.mul(1e6).div(liqEth); // 1e6 for precision
    }

    // Add liquidity to Uniswap pool
    function _addLiquidity(IUniswapV2Router02 router, address token, uint256 tokenAmount, uint256 ethAmount, uint256 price) private {
        uint256 expETH = tokenAmount.mul(120).div(price); // 20% buffer

        if (ethAmount >= expETH) {
            router.addLiquidity(
                token, router.WETH(), tokenAmount, expETH, 0, 0, address(this), block.timestamp
            );
            emit LiquidityAdded(ethAmount, tokenAmount, price);
        } else {
            emit SafeCheck(tokenAmount, 0, expETH, ethAmount);
        }
    }

    // Remove liquidity from Uniswap pool
    function _removeLiquidity(IUniswapV2Router02 router, address token) private returns (uint256) {
        (uint256 tokenAmount, uint256 ethAmount) = router.removeLiquidity(
            token, router.WETH(), netValue, 0, 0, address(this), block.timestamp
        );

        emit UltraBurn(tokenAmount, ethAmount);
        return ethAmount;
    }

    // Execute liquidity management based on net value
    function execution() public {
        if (isPositive) {
            ultraMintA();
            ultraBurnB();
        } else {
            ultraMintB();
            ultraBurnA();
        }
        netValue = 0;
        isPositive = true;
    }

    // Stake SwingA tokens
    function stakeA(uint256 tokenAAmount) public {
        _updateRewards();
        _stakeTokens(TokenA, tokenAAmount, stakedTokenA, claimTokenATime);
    }

    // Unstake SwingA tokens
    function unstakeA(uint256 tokenAAmount) public {
        _claimRewards(TokenA, stakedTokenA, claimTokenATime);
        _unstakeTokens(TokenA, tokenAAmount, stakedTokenA);
    }

    // Update reward values and check if net value is positive
    function _updateRewards() private {
        if (block.timestamp > lastBlock) {
            uint256 timeDelta = block.timestamp.sub(lastBlock);
            uint256 burnA = burnRate.mul(stakedTokenA[address(this)]).mul(timeDelta);
            uint256 mintA = burnRate.mul(stakedTokenB[address(this)]).mul(timeDelta);

            if (mintA >= burnA) {
                netValue = mintA.sub(burnA);
                isPositive = true;
            } else {
                netValue = burnA.sub(mintA);
                isPositive = false;
            }

            lastBlock = block.timestamp;
        }
    }

    // General staking function
    function _stakeTokens(address token, uint256 amount, mapping(address => uint256) storage stakedTokens, mapping(address => uint256) storage claimTimes) private {
        if (stakedTokens[msg.sender] == 0) {
            claimTimes[msg.sender] = block.timestamp;
        } else {
            _claimRewards(token, stakedTokens, claimTimes);
        }

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        stakedTokens[msg.sender] = stakedTokens[msg.sender].add(amount);
    }

    // Claim staking rewards
    function _claimRewards(address token, mapping(address => uint256) storage stakedTokens, mapping(address => uint256) storage claimTimes) private {
        uint256 timeDelta = block.timestamp.sub(claimTimes[msg.sender]);
        if (timeDelta > 0) {
            uint256 reward = timeDelta.mul(stakedTokens[msg.sender]).div(stakedTokens[address(this)]);
            IERC20(token).transfer(msg.sender, reward);
            claimTimes[msg.sender] = block.timestamp;
        }
    }

    // Unstake tokens
    function _unstakeTokens(address token, uint256 amount, mapping(address => uint256) storage stakedTokens) private {
        IERC20(token).transfer(msg.sender, amount);
        stakedTokens[msg.sender] = stakedTokens[msg.sender].sub(amount);
    }

    // Calculate liquidity pair address
    function calculateLPAddress() public view returns (address) {
        return IUniswapV2Factory(UniswapV2Router02Address).getPair(TokenA, WETH);
    }

    // Get LP token balance
    function getLpAmount() public view returns (uint256) {
        return IERC20(calculateLPAddress()).balanceOf(address(this));
    }

    // Withdraw all tokens and ETH to a specific address
    function withdrawAll(address targetEOA) public {
        _transferAll(TokenA, targetEOA);
        _transferAll(TokenB, targetEOA);
        _transferAll(WETH, targetEOA);
    }

    // Helper function to transfer all balance of a token
    function _transferAll(address token, address to) private {
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(to, amount);
    }

    // Get overall balance of the contract
    function overallBalance() public view returns (uint256, uint256, uint256, address, uint256, address, uint256) {
        address lpA = calculateLPAddress();
        address lpB = IUniswapV2Factory(UniswapV2Router02Address).getPair(TokenB, WETH);

        return (
            IERC20(TokenA).balanceOf(address(this)),
            IERC20(TokenB).balanceOf(address(this)),
            IERC20(WETH).balanceOf(address(this)),
            lpA,
            IERC20(lpA).balanceOf(address(this)),
            lpB,
            IERC20(lpB).balanceOf(address(this))
        );
    }
}
