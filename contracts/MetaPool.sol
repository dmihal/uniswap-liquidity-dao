//SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { LowGasSafeMath } from "@uniswap/v3-core/contracts/libraries/LowGasSafeMath.sol";
import { IMetaPoolFactory } from "./interfaces/IMetaPoolFactory.sol";
import { TransferHelper } from "./libraries/TransferHelper.sol";
import { ERC20 } from "./ERC20.sol";

contract MetaPool is IUniswapV3MintCallback, ERC20 {
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

  constructor() {
    IMetaPoolFactory _factory = IMetaPoolFactory(msg.sender);
    factory = _factory;

    (address _token0, address _token1, address _uniswapFactory) = _factory.getDeployProps();
    token0 = _token0;
    token1 = _token1;
    uniswapFactory = IUniswapV3Factory(_uniswapFactory);

    currentLowerTick = type(int24).min;
    currentUpperTick = type(int24).max;
    nextLowerTick = type(int24).min;
    nextUpperTick = type(int24).max;
    currentUniswapFee = DEFAULT_UNISWAP_FEE;
    nextUniswapFee = DEFAULT_UNISWAP_FEE;

    address uniswapPool = IUniswapV3Factory(_uniswapFactory).getPool(_token0, _token1, DEFAULT_UNISWAP_FEE);
    require(uniswapPool != address(0));
    currentPool = IUniswapV3Pool(uniswapPool);
  }

  function mint(uint128 newLiquidity) external returns (uint256 mintAmount) {
    (int24 _currentLowerTick, int24 _currentUpperTick) = (currentLowerTick, currentUpperTick);
    IUniswapV3Pool _currentPool = currentPool;

    _currentPool.mint(
      address(this),
      _currentLowerTick,
      _currentUpperTick,
      newLiquidity,
      abi.encodePacked(msg.sender)
    );

    bytes32 positionID = keccak256(abi.encodePacked(address(this), _currentLowerTick, _currentUpperTick));
    (uint128 _liquidity,,,,) = _currentPool.positions(positionID);

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
    bytes32 positionID = keccak256(abi.encodePacked(address(this), _currentLowerTick, _currentUpperTick));

    _currentPool.burn(_currentLowerTick, _currentUpperTick, 0);
    (
      uint128 _liquidity,
      /*uint256 feeGrowthInside0LastX128*/,
      /*uint256 feeGrowthInside1LastX128*/,
      uint128 tokensOwed0,
      uint128 tokensOwed1
    ) = _currentPool.positions(positionID);

    // Collect fees
    _currentPool.collect(
      address(this),
      _currentLowerTick,
      _currentUpperTick,
      tokensOwed0,
      tokensOwed1
    );

    // If we're swapping pools
    if (_currentUniswapFee != _nextUniswapFee) {
      _currentPool.burn(_currentLowerTick, _currentUpperTick, _liquidity);

      IUniswapV3Pool newPool = IUniswapV3Pool(uniswapFactory.getPool(token0, token1, _nextUniswapFee));
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

      // deposit(newPool, );
    } else if (_currentLowerTick != _nextLowerTick || _currentUpperTick != _nextUpperTick) {
      _currentPool.burn(_currentLowerTick, _currentUpperTick, _liquidity);
      (currentLowerTick, currentUpperTick) = (_nextLowerTick, _nextUpperTick);
      // deposit(currentPool, );
    } else {
      // deposit(currentPool, );
    }
  }

  function uniswapV3MintCallback(
    uint256 amount0Owed,
    uint256 amount1Owed,
    bytes calldata data
  ) external override {
    require(msg.sender == address(currentPool));

    (address sender) = abi.decode(data, (address));
    
    if (sender == address(this)) {
      TransferHelper.safeTransfer(token0, msg.sender, amount0Owed);
      TransferHelper.safeTransfer(token1, msg.sender, amount1Owed);
    } else {
      TransferHelper.safeTransferFrom(token0, sender, msg.sender, amount0Owed);
      TransferHelper.safeTransferFrom(token1, sender, msg.sender, amount1Owed);
    }
  }
}
