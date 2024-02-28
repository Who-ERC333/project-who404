//SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

struct PoolData {
  address poolAddress;
  address quoteToken;
  uint24 fee;
  uint256 positionId;
  uint160 sqrtPriceX96;
  int24 tickLower;
  int24 tickUpper;
  uint128 liquidity;
}