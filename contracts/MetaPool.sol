//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { TickMath } from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import { IMetaPoolFactory } from "./interfaces/IMetaPoolFactory.sol";
import { TransferHelper } from "./libraries/TransferHelper.sol";
import { LiquidityAmounts } from "./libraries/LiquidityAmounts.sol";
import { ERC20 } from "./ERC20.sol";

contract MetaPool is IUniswapV3MintCallback, IUniswapV3SwapCallback, ERC20 {
  using LowGasSafeMath for uint256;

  IMetaPoolFactory public immutable factory;
  address public immutable token0;
  address public immutable token1;

  int24 public currentLowerTick;
  int24 public currentUpperTick;
  uint24 public currentUniswapFee;

  int24 public nextLowerTick;
  int24 public nextUpperTick;
  uint24 public nextUniswapFee;

  IUniswapV3Pool public currentPool;
  IUniswapV3Factory public immutable uniswapFactory;

  uint24 private constant DEFAULT_UNISWAP_FEE = 3000;
  int24 private constant MIN_TICK = -887220;
  int24 private constant MAX_TICK = 887220;

  event ParamsAdjusted(int24 newLowerTick, int24 newUpperTick, uint24 newUniswapFee);

  constructor() {
    IMetaPoolFactory _factory = IMetaPoolFactory(msg.sender);
    factory = _factory;

    (address _token0, address _token1, address _uniswapFactory) = _factory.getDeployProps();
    token0 = _token0;
    token1 = _token1;
    uniswapFactory = IUniswapV3Factory(_uniswapFactory);

    // All metapools start with 0.30% fees & liquidity spread across the entire curve
    currentLowerTick = MIN_TICK;
    currentUpperTick = MAX_TICK;
    nextLowerTick = MIN_TICK;
    nextUpperTick = MAX_TICK;
    currentUniswapFee = DEFAULT_UNISWAP_FEE;
    nextUniswapFee = DEFAULT_UNISWAP_FEE;

    address uniswapPool = IUniswapV3Factory(_uniswapFactory).getPool(_token0, _token1, DEFAULT_UNISWAP_FEE);
    require(uniswapPool != address(0));
    currentPool = IUniswapV3Pool(uniswapPool);
  }

  function adjustParams(int24 newLowerTick, int24 newUpperTick, uint24 newUniswapFee) external {
    require(msg.sender == factory.owner());
    (nextLowerTick, nextUpperTick, nextUniswapFee) = (newLowerTick, newUpperTick, newUniswapFee);
    emit ParamsAdjusted(newLowerTick, newUpperTick, newUniswapFee);
  }

  function mint(uint128 newLiquidity) external returns (uint256 mintAmount) {
    (int24 _currentLowerTick, int24 _currentUpperTick) = (currentLowerTick, currentUpperTick);
    IUniswapV3Pool _currentPool = currentPool;

    bytes32 positionID = keccak256(abi.encodePacked(address(this), _currentLowerTick, _currentUpperTick));
    (uint128 _liquidity,,,,) = _currentPool.positions(positionID);

    _currentPool.mint(
      address(this),
      _currentLowerTick,
      _currentUpperTick,
      newLiquidity,
      abi.encode(msg.sender)
    );

    uint256 _totalSupply = totalSupply;
    if (_totalSupply == 0) {
      mintAmount = newLiquidity;
    } else {
      mintAmount = uint256(newLiquidity).mul(totalSupply) / _liquidity;
    }
    _mint(msg.sender, mintAmount);
  }

  function burn(uint256 burnAmount) external returns (uint256 amount0, uint256 amount1, uint128 liquidityBurned) {
    (int24 _currentLowerTick, int24 _currentUpperTick) = (currentLowerTick, currentUpperTick);
    IUniswapV3Pool _currentPool = currentPool;
    uint256 _totalSupply = totalSupply;

    bytes32 positionID = keccak256(abi.encodePacked(address(this), _currentLowerTick, _currentUpperTick));
    (uint128 _liquidity,,,,) = _currentPool.positions(positionID);

    _burn(msg.sender, burnAmount);

    uint256 _liquidityBurned = burnAmount.mul(_totalSupply) / _liquidity;
    require(_liquidityBurned < type(uint128).max);
    liquidityBurned = uint128(_liquidityBurned);

    (amount0, amount1) = currentPool.burn(
      _currentLowerTick,
      _currentUpperTick,
      liquidityBurned
    );

    // Withdraw tokens to user
    _currentPool.collect(
      msg.sender,
      _currentLowerTick,
      _currentUpperTick,
      uint128(amount0), // cast can't overflow
      uint128(amount1) // cast can't overflow
    );
  }

  function rebalance() external {
    // Read all this from storage to minimize SLOADs
    (
      IUniswapV3Pool _currentPool,
      int24 _currentLowerTick,
      int24 _currentUpperTick,
      uint24 _currentUniswapFee,
      int24 _nextLowerTick,
      int24 _nextUpperTick,
      uint24 _nextUniswapFee
    ) = (
      currentPool,
      currentLowerTick,
      currentUpperTick,
      currentUniswapFee,
      nextLowerTick,
      nextUpperTick,
      nextUniswapFee
    );

    // If we're swapping pools
    if (_currentUniswapFee != _nextUniswapFee) {
      bytes32 positionID = keccak256(abi.encodePacked(address(this), _currentLowerTick, _currentUpperTick));
      (uint128 _liquidity,,,,) = _currentPool.positions(positionID);
      (uint256 collected0, uint256 collected1) = withdraw(_currentPool, _currentLowerTick, _currentUpperTick, _liquidity, address(this));

      IUniswapV3Pool newPool = IUniswapV3Pool(uniswapFactory.getPool(token0, token1, _nextUniswapFee));
      // Store new paramaters as "current"
      (
        currentLowerTick,
        currentUpperTick,
        currentUniswapFee,
        currentPool
      ) = (
        _nextLowerTick,
        _nextUpperTick,
        _nextUniswapFee,
        newPool
      );

      deposit(newPool, _nextLowerTick, _nextUpperTick, collected0, collected1);
    } else if (_currentLowerTick != _nextLowerTick || _currentUpperTick != _nextUpperTick) {
      // We're just adjusting ticks
      bytes32 positionID = keccak256(abi.encodePacked(address(this), _currentLowerTick, _currentUpperTick));
      (uint128 _liquidity,,,,) = _currentPool.positions(positionID);
      (uint256 collected0, uint256 collected1) = withdraw(_currentPool, _currentLowerTick, _currentUpperTick, _liquidity, address(this));
      
      // Store new ticks
      (currentLowerTick, currentUpperTick) = (_nextLowerTick, _nextUpperTick);
      
      deposit(_currentPool, _nextLowerTick, _nextUpperTick, collected0, collected1);
    } else {
      (uint256 collected0, uint256 collected1) = withdraw(_currentPool, _currentLowerTick, _currentUpperTick, 0, address(this));
      deposit(_currentPool, _currentLowerTick, _currentUpperTick, collected0, collected1);
    }
  }

  function deposit(
    IUniswapV3Pool _currentPool,
    int24 lowerTick,
    int24 upperTick,
    uint256 amount0,
    uint256 amount1
  ) private {
    (uint160 sqrtRatioX96,,,,,,) = _currentPool.slot0();

    // First, deposit as much as we can
    uint128 baseLiquidity = LiquidityAmounts.getLiquidityForAmounts(
      sqrtRatioX96,
      TickMath.getSqrtRatioAtTick(lowerTick),
      TickMath.getSqrtRatioAtTick(upperTick),
      amount0,
      amount1
    );
    (uint256 amountDeposited0, uint256 amountDeposited1) = _currentPool.mint(
      address(this),
      lowerTick,
      upperTick,
      baseLiquidity,
      abi.encode(address(this))
    );
    amount0 -= amountDeposited0;
    amount1 -= amountDeposited1;

    // If we still have some leftover, we need to swap so it's balanced
    // This part is still a PoC, would need much more intelligent swapping
    if (amount0 > 0 || amount1 > 0) {
      // TODO: this is a hacky method that only works at somewhat-balanced pools
      bool zeroForOne = amount0 > amount1;
      (int256 amount0Delta, int256 amount1Delta) = _currentPool.swap(
        address(this),
        zeroForOne,
        int256(zeroForOne ? amount0 : amount1) / 2,
        zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
        abi.encode(address(this))
      );

      amount0 = uint256(int256(amount0) - amount0Delta);
      amount1 = uint256(int256(amount1) - amount1Delta);

      // Add liquidity a second time
      (sqrtRatioX96,,,,,,) = _currentPool.slot0();
      uint128 swapLiquidity = LiquidityAmounts.getLiquidityForAmounts(
        sqrtRatioX96,
        TickMath.getSqrtRatioAtTick(lowerTick),
        TickMath.getSqrtRatioAtTick(upperTick),
        amount0,
        amount1
      );

      _currentPool.mint(
        address(this),
        lowerTick,
        upperTick,
        swapLiquidity,
        abi.encode(address(this))
      );
    }
  }

  function withdraw(
    IUniswapV3Pool _currentPool,
    int24 lowerTick,
    int24 upperTick,
    uint128 liquidity,
    address recipient
  ) private returns (uint256 collected0, uint256 collected1) {
      // We can request MAX_INT, and Uniswap will just give whatever we're owed
    uint128 requestAmount0 = type(uint128).max;
    uint128 requestAmount1 = type(uint128).max;

    (uint256 _owed0, uint256 _owed1) = _currentPool.burn(lowerTick, upperTick, liquidity);

    // If we're withdrawing for a specific user, then we only want to withdraw what they're owed
    if (recipient != address(this)) {
      // TODO: can we trust Uniswap and safely cast here?
      requestAmount0 = uint128(_owed0);
      requestAmount1 = uint128(_owed1);
    }

    // Collect all owed
    (collected0, collected1) = _currentPool.collect(
      recipient,
      lowerTick,
      upperTick,
      requestAmount0,
      requestAmount1
    );
  }

  function uniswapV3MintCallback(
    uint256 amount0Owed,
    uint256 amount1Owed,
    bytes calldata data
  ) external override {
    require(msg.sender == address(currentPool));

    (address sender) = abi.decode(data, (address));

    if (sender == address(this)) {
      if (amount0Owed > 0) {
        TransferHelper.safeTransfer(token0, msg.sender, amount0Owed);
      }
      if (amount1Owed > 0) {
        TransferHelper.safeTransfer(token1, msg.sender, amount1Owed);
      }
    } else {
      if (amount0Owed > 0) {
        TransferHelper.safeTransferFrom(token0, sender, msg.sender, amount0Owed);
      }
      if (amount1Owed > 0) {
        TransferHelper.safeTransferFrom(token1, sender, msg.sender, amount1Owed);
      }
    }
  }

  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata /*data*/
  ) external override {
    require(msg.sender == address(currentPool));

    if (amount0Delta > 0) {
      TransferHelper.safeTransfer(token0, msg.sender, uint256(amount0Delta));
    } else if (amount1Delta > 0) {
      TransferHelper.safeTransfer(token1, msg.sender, uint256(amount1Delta));
    }
  }
}
