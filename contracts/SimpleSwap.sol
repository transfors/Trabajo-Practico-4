// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SimpleSwap
/// @notice A minimal implementation of a two-token liquidity pool for swapping and providing/removing liquidity
contract SimpleSwap is ReentrancyGuard {
    /// @notice First token in the pair (sorted by address)
    address public token0;

    /// @notice Second token in the pair
    address public token1;

    /// @notice Reserve amount for token0
    uint256 public reserve0;

    /// @notice Reserve amount for token1
    uint256 public reserve1;

    /// @notice Total supply of liquidity tokens minted
    uint256 public totalLiquidity;

    /// @notice Tracks liquidity provided by each address
    mapping(address => uint256) public liquidityProvided;

    /// @notice Emitted when liquidity is added to the pool
    /// @param provider The address adding liquidity
    /// @param amountA Amount of tokenA added
    /// @param amountB Amount of tokenB added
    /// @param liquidityMinted Amount of liquidity tokens minted
    /// @param timestamp Timestamp of the action
    event LiquidityAdded(
        address indexed provider,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidityMinted,
        uint256 timestamp
    );

    /// @notice Emitted when liquidity is removed from the pool
    /// @param provider The address removing liquidity
    /// @param amountA Amount of tokenA withdrawn
    /// @param amountB Amount of tokenB withdrawn
    /// @param timestamp Timestamp of the action
    event LiquidityRemoved(
        address indexed provider,
        uint256 amountA,
        uint256 amountB,
        uint256 timestamp
    );

    /// @notice Emitted when a token swap occurs
    /// @param swapper Address performing the swap
    /// @param tokenIn Token sent to the pool
    /// @param tokenOut Token received from the pool
    /// @param timestamp Timestamp of the swap
    event TokensSwapped(
        address indexed swapper,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 timestamp
    );

    /// @notice Constructor sets and sorts the token addresses
    /// @param _tokenA Address of the first token
    /// @param _tokenB Address of the second token
    constructor(address _tokenA, address _tokenB) {
        require(_tokenA != address(0) && _tokenB != address(0), "Invalid token address");
        require(_tokenA != _tokenB, "Tokens must be different");

        if (_tokenA < _tokenB) {
            token0 = _tokenA;
            token1 = _tokenB;
        } else {
            token0 = _tokenB;
            token1 = _tokenA;
        }
    }

    /// @notice Context for internal calculation in addLiquidity()
    struct AddLiquidityContext {
        uint256 reserveA;
        uint256 reserveB;
        uint256 totalLiquidity;
        bool isTokenA_token0;
    }

    /// @notice Context for internal calculation in removeLiquidity()
    struct RemoveLiquidityContext {
        bool isTokenA_token0;
        uint256 reserveA;
        uint256 reserveB;
        uint256 userLiquidity;
        uint256 totalLiquidity;
    }

    /// @notice Context for internal calculation in swapExactTokensForTokens()
    struct SwapContext {
        bool isTokenIn_token0;
        uint256 reserveIn;
        uint256 reserveOut;
        uint256 amountOut;
    }

    /// @notice Context for internal calculation in getPrice()
    struct PriceContext {
        bool isTokenA_token0;
        uint256 reserveA;
        uint256 reserveB;
    }

    /// @dev Ensures a transaction executes before the deadline
    /// @param deadline Timestamp by which the transaction must be executed
    modifier ensure(uint256 deadline) {
        require(block.timestamp <= deadline, "Transaction expired");
        _;
    }

    /// @notice Adds liquidity to the pool
    /// @param _tokenA First token address
    /// @param _tokenB Second token address
    /// @param amountADesired Desired amount of tokenA to deposit
    /// @param amountBDesired Desired amount of tokenB to deposit
    /// @param amountAMin Minimum amount of tokenA to deposit
    /// @param amountBMin Minimum amount of tokenB to deposit
    /// @param to Address that receives the liquidity tokens
    /// @param deadline Transaction must be executed before this timestamp
    /// @return actualAmountA Final deposited amount of tokenA
    /// @return actualAmountB Final deposited amount of tokenB
    /// @return liquidity Amount of liquidity tokens minted
    function addLiquidity(
        address _tokenA,
        address _tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        ensure(deadline)
        returns (
            uint256 actualAmountA,
            uint256 actualAmountB,
            uint256 liquidity
        )
    {
        require(
            (_tokenA == token0 && _tokenB == token1) ||
            (_tokenA == token1 && _tokenB == token0),
            "Invalid token"
        );
        require(to != address(0), "Invalid 'to' address");
        require(amountADesired > 0 || amountBDesired > 0, "Cannot add zero liquidity");

        AddLiquidityContext memory ctx;
        ctx.isTokenA_token0 = (_tokenA == token0);
        ctx.reserveA = ctx.isTokenA_token0 ? reserve0 : reserve1;
        ctx.reserveB = ctx.isTokenA_token0 ? reserve1 : reserve0;
        ctx.totalLiquidity = totalLiquidity;

        if (ctx.totalLiquidity == 0) {
            actualAmountA = amountADesired;
            actualAmountB = amountBDesired;
            liquidity = Math.sqrt(actualAmountA * actualAmountB);
            require(liquidity > 0, "Liquidity must be > 0");
        } else {
            uint256 amountBOptimal = (ctx.reserveA > 0)
                ? (amountADesired * ctx.reserveB) / ctx.reserveA
                : 0;

            if (amountBOptimal <= amountBDesired) {
                require(
                    amountBOptimal >= amountBMin,
                    "Slippage B too high"
                );
                actualAmountA = amountADesired;
                actualAmountB = amountBOptimal;
            } else {
                uint256 amountAOptimal = (ctx.reserveB > 0)
                    ? (amountBDesired * ctx.reserveA) / ctx.reserveB
                    : 0;
                require(
                    amountAOptimal >= amountAMin,
                    "Splippage a too high"
                );
                actualAmountA = amountAOptimal;
                actualAmountB = amountBDesired;
            }

            liquidity = Math.min(
                (actualAmountA * ctx.totalLiquidity) / ctx.reserveA,
                (actualAmountB * ctx.totalLiquidity) / ctx.reserveB
            );
            require(liquidity > 0, "Zero liquidity not allowed");
        }

        IERC20(_tokenA).transferFrom(msg.sender, address(this), actualAmountA);
        IERC20(_tokenB).transferFrom(msg.sender, address(this), actualAmountB);

        if (ctx.isTokenA_token0) {
            reserve0 = ctx.reserveA + actualAmountA;
            reserve1 = ctx.reserveB + actualAmountB;
        } else {
            reserve0 = ctx.reserveB + actualAmountB;
            reserve1 = ctx.reserveA + actualAmountA;
        }

        totalLiquidity = ctx.totalLiquidity + liquidity;
        liquidityProvided[to] += liquidity;

        emit LiquidityAdded(
            msg.sender,
            actualAmountA,
            actualAmountB,
            liquidity,
            block.timestamp
        );

        return (actualAmountA, actualAmountB, liquidity);
    }

    /// @notice Removes liquidity from the pool
    /// @param _tokenA Address of the first token
    /// @param _tokenB Address of the second token
    /// @param liquidityToBurn Amount of liquidity tokens to burn
    /// @param amountAMin Minimum amount of tokenA to withdraw
    /// @param amountBMin Minimum amount of tokenB to withdraw
    /// @param to Address that receives the withdrawn tokens
    /// @param deadline Transaction must be executed before this timestamp
    /// @return amountAWithdrawn Final amount of tokenA withdrawn
    /// @return amountBWithdrawn Final amount of tokenB withdrawn
    function removeLiquidity(
        address _tokenA,
        address _tokenB,
        uint256 liquidityToBurn,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        ensure(deadline)
        returns (uint256 amountAWithdrawn, uint256 amountBWithdrawn)
    {
        require(
            (_tokenA == token0 && _tokenB == token1) ||
            (_tokenA == token1 && _tokenB == token0),
            "Invalid token"
        );
        require(to != address(0), "Invalid 'to' address");
        require(liquidityToBurn > 0, "Cannot remove zero liquidity");

        RemoveLiquidityContext memory ctx;
        ctx.isTokenA_token0 = (_tokenA == token0);
        ctx.reserveA = ctx.isTokenA_token0 ? reserve0 : reserve1;
        ctx.reserveB = ctx.isTokenA_token0 ? reserve1 : reserve0;
        ctx.userLiquidity = liquidityProvided[msg.sender];
        ctx.totalLiquidity = totalLiquidity;

        require(ctx.userLiquidity >= liquidityToBurn, "Insufficient Liquidity");

        amountAWithdrawn = (liquidityToBurn * ctx.reserveA) / ctx.totalLiquidity;
        amountBWithdrawn = (liquidityToBurn * ctx.reserveB) / ctx.totalLiquidity;

        require(amountAWithdrawn >= amountAMin, "TokenA slippage error");
        require(amountBWithdrawn >= amountBMin, "TokenB slippage error");

        totalLiquidity = ctx.totalLiquidity - liquidityToBurn;
        liquidityProvided[msg.sender] = ctx.userLiquidity - liquidityToBurn;

        if (ctx.isTokenA_token0) {
            reserve0 = ctx.reserveA - amountAWithdrawn;
            reserve1 = ctx.reserveB - amountBWithdrawn;
        } else {
            reserve0 = ctx.reserveB - amountBWithdrawn;
            reserve1 = ctx.reserveA - amountAWithdrawn;
        }

        IERC20(_tokenA).transfer(to, amountAWithdrawn);
        IERC20(_tokenB).transfer(to, amountBWithdrawn);

        emit LiquidityRemoved(
            msg.sender,
            amountAWithdrawn,
            amountBWithdrawn,
            block.timestamp
        );

        return (amountAWithdrawn, amountBWithdrawn);
    }

    /// @notice Executes a token swap between token0 and token1
    /// @param amountIn Amount of input tokens sent to the pool
    /// @param amountOutMin Minimum amount of output tokens required
    /// @param path Array of token addresses: [tokenIn, tokenOut]
    /// @param to Address that receives the output tokens
    /// @param deadline Transaction must be executed before this timestamp
    /// @return amounts Array with [amountIn, amountOut]
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path.length == 2, "Only 1 hop allowed");
        require(to != address(0), "Invalid 'to' address");
        require(amountIn > 0, "Input must be > 0");

        address _tokenIn = path[0];
        address _tokenOut = path[1];

        require(
            (_tokenIn == token0 && _tokenOut == token1) ||
            (_tokenIn == token1 && _tokenOut == token0),
            "Invalid token"
        );

        IERC20(_tokenIn).transferFrom(msg.sender, address(this), amountIn);

        SwapContext memory ctx;
        ctx.isTokenIn_token0 = (_tokenIn == token0);
        ctx.reserveIn = ctx.isTokenIn_token0 ? reserve0 : reserve1;
        ctx.reserveOut = ctx.isTokenIn_token0 ? reserve1 : reserve0;

        require(ctx.reserveIn > 0 && ctx.reserveOut > 0, "Reserves too low");

        ctx.amountOut = getAmountOut(amountIn, ctx.reserveIn, ctx.reserveOut);

        require(ctx.amountOut >= amountOutMin, "Excessive slippage");

        if (ctx.isTokenIn_token0) {
            reserve0 = ctx.reserveIn + amountIn;
            reserve1 = ctx.reserveOut - ctx.amountOut;
        } else {
            reserve1 = ctx.reserveIn + amountIn;
            reserve0 = ctx.reserveOut - ctx.amountOut;
        }

        IERC20(_tokenOut).transfer(to, ctx.amountOut);

        emit TokensSwapped(msg.sender, _tokenIn, _tokenOut, block.timestamp);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = ctx.amountOut;

        return amounts;
    }

    /// @notice Returns the price of tokenA in terms of tokenB (scaled by 1e18)
    /// @param _tokenA The token to price
    /// @param _tokenB The token used as reference
    /// @return price The price of tokenA in tokenB units (scaled)
    function getPrice(address _tokenA, address _tokenB)
        external
        view
        returns (uint256 price)
    {
        require(_tokenA != address(0) && _tokenB != address(0), "Invalid tokens");
        require(
            (_tokenA == token0 && _tokenB == token1) ||
            (_tokenA == token1 && _tokenB == token0),
            "Invalid token"
        );

        if (reserve0 == 0 || reserve1 == 0) return 0;

        PriceContext memory ctx;
        ctx.isTokenA_token0 = (_tokenA == token0);
        ctx.reserveA = ctx.isTokenA_token0 ? reserve0 : reserve1;
        ctx.reserveB = ctx.isTokenA_token0 ? reserve1 : reserve0;

        return (ctx.reserveB * 1e18) / ctx.reserveA;
    }

    /// @notice Calculates the output amount for a given input swap, including a 0.3% fee
    /// @param amountIn Amount of input tokens sent to the pool
    /// @param reserveIn Current reserve of the input token
    /// @param reserveOut Current reserve of the output token
    /// @return amountOut Amount of output tokens that will be received
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) public pure returns (uint256 amountOut) {
        uint256 amountInWithFee = (amountIn * 997) / 1000;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithFee;
        if (denominator == 0) return 0;
        return numerator / denominator;
    }
}